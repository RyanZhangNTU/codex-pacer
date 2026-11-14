import XCTest
import PacerCore
@testable import PacerIsland
import PacerTestSupport

@MainActor
final class ModuleLibrarySettingsTests: XCTestCase {
    private func model(installed: Set<AgentProvider> = []) throws -> (IslandModel, UserDefaults) {
        let domain = testDefaultsName("module-library-tests")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        let model = IslandModel(demo: true, demoArguments: nil, defaults: defaults,
            installation: ProviderInstallationDetection(codexInstalled: installed.contains(.codex), claudeInstalled: installed.contains(.claude),
                                                        deepseekInstalled: installed.contains(.deepseek), additional: installed))
        addTeardownBlock {
            await model.shutdown()
            removeTestDefaults(domain)
        }
        return (model, defaults)
    }

    func testSidebarListsServicesFoundOrTurnedOnThenRemoteAndTheLibrary() throws {
        let (model, _) = try model(installed: [.claude])
        var modules = ProviderModules()
        modules.setMode(.enabled, for: .workbuddy)
        let library = model.moduleLibrary(modules)
        XCTAssertEqual(library.prominent.map(\.provider), [.claude, .workbuddy], "Found or turned on, in registry order")
        XCTAssertEqual(library.collapsed.map(\.provider), [.codex, .deepseek])
        let services = SettingsPane.groups(services: library.prominent.map(\.provider))[1]
        XCTAssertEqual(services, [.claude, SettingsPane(provider: .workbuddy), .remote, .modules], "The library closes the Services group")
        XCTAssertEqual(SettingsPane(stored: "codex"), .codex, "A hidden built-in page still opens from saved state")
        XCTAssertEqual(SettingsPane(stored: "harness.workbuddy")?.provider, .workbuddy)
        XCTAssertEqual(SettingsPane(stored: "modules"), .modules)
    }

    func testProgressRingsAreOnUntilListedAndTurnCreditsShowUntilHidden() throws {
        let (model, defaults) = try model()
        XCTAssertTrue(model.showsHarnessProgress(.workbuddy), "A new module's ring is on without any saved choice")
        defaults.set(["workbuddy"], forKey: IslandModel.disabledHarnessProgressKey)
        XCTAssertFalse(model.showsHarnessProgress(.workbuddy))
        XCTAssertTrue(model.hiddenTurnCredits.isEmpty)
        defaults.set(["workbuddy", "unknown-module"], forKey: IslandModel.hiddenTurnCreditsKey)
        XCTAssertEqual(model.hiddenTurnCredits, [.workbuddy], "IDs this version does not know are ignored")
        XCTAssertEqual(model.taskPresentationOptions(for: []).hiddenTurnCredits, [.workbuddy])
    }

    func testAccountSiteFallsBackToAutomaticAndDataFolderWinsOverTheDefault() throws {
        let (model, defaults) = try model()
        XCTAssertEqual(model.harnessAccountSite(.workbuddy), "automatic")
        let site = try XCTUnwrap(HarnessRegistry.descriptor(for: .workbuddy)?.accountCredits?.sites.first?.id)
        model.setHarnessAccountSite(.workbuddy, site)
        XCTAssertEqual(model.harnessAccountSite(.workbuddy), site)
        defaults.set([AgentProvider.workbuddy.rawValue: "removed-site"], forKey: IslandModel.harnessAccountSitesKey)
        XCTAssertEqual(model.harnessAccountSite(.workbuddy), "automatic", "A site the registry no longer lists reads as automatic")

        let folder = "/private/tmp/pacer-workbuddy-data-" + UUID().uuidString
        defaults.set([AgentProvider.workbuddy.rawValue: folder], forKey: IslandModel.harnessHomesKey)
        XCTAssertEqual(model.localHarnessHome(.workbuddy)?.path, folder)
        defaults.set([AgentProvider.workbuddy.rawValue: ""], forKey: IslandModel.harnessHomesKey)
        XCTAssertNotEqual(model.localHarnessHome(.workbuddy)?.path, "", "An empty folder returns to the default")
    }
}
