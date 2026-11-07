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
