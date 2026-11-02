import XCTest
@testable import PacerCore
@testable import PacerIsland

@MainActor
final class DemoSettingsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let arguments = ["--demo", "--demo-claude", "--demo-deepseek", "--demo-cloud"]

    private func defaults() throws -> UserDefaults {
        let domain = "DemoSettingsTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        addTeardownBlock { defaults.removePersistentDomain(forName: domain) }
        defaults.set("/synthetic/demo/codex", forKey: "codexHome")
        defaults.set("/synthetic/demo/claude", forKey: "claudeHome")
        defaults.set("/synthetic/demo/deepseek", forKey: "deepseekHome")
        defaults.set(false, forKey: "monitorSSH"); defaults.set(false, forKey: "monitorRemoteControl")
        return defaults
    }

    func testSettingsPreserveDemoTasksStageRatesAndRequests() async throws {
        let defaults = try defaults(), clock = now
        let model = IslandModel(demo: true, demoClock: { clock }, demoArguments: arguments, defaults: defaults)
        XCTAssertEqual(Set(model.enabledProviders), Set(AgentProvider.allCases), "Demo automatic choices use synthetic installations")
        for stage in DemoTaskStage.allCases {
            model.setDemoStage(stage)
            let before = model.activities.sorted { $0.id < $1.id }
            let requests = model.pendingInputRequests
            let rate = model.rate
            let unread = Set(model.pendingCompletions.map(\.id))
            XCTAssertFalse(before.isEmpty)
            for sourceChanged in [false, true] {
                defaults.set(!defaults.bool(forKey: "hideProjects"), forKey: "hideProjects")
                defaults.set("/synthetic/demo/home", forKey: "codexHome")
                defaults.set(false, forKey: "monitorSSH")
                model.applySettings(sourceChanged: sourceChanged)
                XCTAssertEqual(model.activities.sorted { $0.id < $1.id }, before)
                XCTAssertEqual(model.pendingInputRequests, requests)
                XCTAssertEqual(model.rate, rate)
                XCTAssertEqual(Set(model.pendingCompletions.map(\.id)), unread)
            }
        }
        model.setDemoStage(.thinking)
        XCTAssertTrue(model.activities.filter { $0.provider == .codex }.allSatisfy { $0.phase == .running },
            "The same synthetic turn can replay a running stage after completion")
        await model.shutdown()
    }

    func testEveryModuleCombinationFiltersDemoTasksRequestsAndEndings() async throws {
        let clock = now
        for mask in 0..<8 {
            let defaults = try defaults()
            var modules = ProviderModules()
            let enabled = Set(AgentProvider.allCases.enumerated().compactMap { index, provider in
                mask & (1 << index) == 0 ? nil : provider
            })
            for provider in AgentProvider.allCases { modules.setMode(enabled.contains(provider) ? .enabled : .disabled, for: provider) }
            modules.save(to: defaults)
            let model = IslandModel(demo: true, demoClock: { clock }, demoArguments: arguments, defaults: defaults)
            for stage in DemoTaskStage.allCases {
                model.setDemoStage(stage)
                XCTAssertEqual(Set(model.activities.map(\.provider)), enabled)
                XCTAssertTrue(model.visibleActivities.allSatisfy { enabled.contains($0.provider) })
                XCTAssertTrue(model.pendingInputRequests.allSatisfy { enabled.contains($0.provider) })
                XCTAssertTrue(model.pendingCompletions.allSatisfy { enabled.contains($0.provider) })
                if stage == .tool { XCTAssertEqual(model.pendingInputRequests.isEmpty, !enabled.contains(.claude)) }
            }
            await model.shutdown()
        }
    }

    func testModuleChangesRestoreTheSameDemoSnapshotAndUnreadState() async throws {
        let defaults = try defaults(), clock = now
        let model = IslandModel(demo: true, demoClock: { clock }, demoArguments: arguments, defaults: defaults)
        for stage in [DemoTaskStage.tool, .completed] {
            model.setDemoStage(stage)
            let before = model.activities.sorted { $0.id < $1.id }, requests = model.pendingInputRequests
            let unread = Set(model.pendingCompletions.map(\.id))
            for provider in AgentProvider.allCases {
                var modules = ProviderModules()
                modules.setMode(.disabled, for: provider); modules.save(to: defaults)
                model.applySettings(sourceChanged: false)
                XCTAssertEqual(model.activities.sorted { $0.id < $1.id }, before.filter { $0.provider != provider })
                XCTAssertFalse(model.pendingInputRequests.contains { $0.provider == provider })
                XCTAssertFalse(model.pendingCompletions.contains { $0.provider == provider })
                ProviderModules().save(to: defaults)
                model.applySettings(sourceChanged: false)
                XCTAssertEqual(model.activities.sorted { $0.id < $1.id }, before)
                XCTAssertEqual(model.pendingInputRequests, requests)
                XCTAssertEqual(Set(model.pendingCompletions.map(\.id)), unread)
            }
        }
        await model.shutdown()
    }
}
