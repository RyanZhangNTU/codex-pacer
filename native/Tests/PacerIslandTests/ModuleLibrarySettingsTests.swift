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
        XCTAssertEqual(library.collapsed.map(\.provider), [.codex, .deepseek, .workbuddyAI])
        let services = SettingsPane.groups(services: library.prominent.map(\.provider))[1]
        XCTAssertEqual(services, [.claude, SettingsPane(provider: .workbuddy), .modules, .remote], "The library follows the services, then Remote")
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

    func testCreditNoticesStayQuietThroughAStopAndForgetOnlyOnAnAccountChange() throws {
        let (model, _) = try model()
        let low = try JSONDecoder().decode(HarnessAccountCredits.self,
            from: Data(#"{"state":"ready","remaining":5,"total":100,"reserved":0}"#.utf8))
        let credits: [AgentProvider: HarnessAccountCredits] = [.workbuddy: low]
        XCTAssertEqual(model.harnessCreditsAttention.notices(credits, low: true, now: Date()).count, 1)
        // Stopping for sleep publishes an empty account; that must not re-arm the notice.
        model.harnessAccount(.workbuddy)?.stop()
        model.receiveHarnessCredits(.workbuddy)
        XCTAssertTrue(model.harnessCreditsAttention.notices(credits, low: true, now: Date()).isEmpty,
                      "Waking with the same low reading stays quiet")
        model.harnessAccount(.workbuddy)?.onAccountReset?()
        XCTAssertEqual(model.harnessCreditsAttention.notices(credits, low: true, now: Date()).count, 1,
                       "Signing out or switching may bring another account, so it can notify again")
    }

    func testCreditSettingsSaveOnlyChoicesAndKeepModulesThisVersionDoesNotKnow() throws {
        let (model, defaults) = try model()
        XCTAssertEqual(model.creditSettings(.workbuddyAI), .default)
        let unknown = try JSONEncoder().encode(["future-module": HarnessCreditsSettings(center: .available)])
        defaults.set(unknown, forKey: IslandModel.harnessCreditsKey)
        model.setCreditSettings(.workbuddyAI, HarnessCreditsSettings(center: .monthlyRemaining, bar: .monthlyPercent, lowCredits: 250,
                                                                    expiryReminder: false, expiryDays: 7))
        XCTAssertEqual(model.creditSettings(.workbuddyAI).bar, .monthlyPercent)
        XCTAssertEqual(model.creditSettings(.workbuddy), .default, "Each module keeps its own choices")
        let stored = try JSONDecoder().decode([String: HarnessCreditsSettings].self,
                                              from: XCTUnwrap(defaults.data(forKey: IslandModel.harnessCreditsKey)))
        XCTAssertEqual(Set(stored.keys), ["future-module", "workbuddy-ai"], "Another host's module survives a save")
        model.setCreditSettings(.workbuddyAI, .default)
        XCTAssertNil(try JSONDecoder().decode([String: HarnessCreditsSettings].self,
                                              from: XCTUnwrap(defaults.data(forKey: IslandModel.harnessCreditsKey)))["workbuddy-ai"],
                     "Default choices are not stored")
        XCTAssertEqual(IslandModel.loadCreditSettings(defaults)[.workbuddyAI], nil)
        XCTAssertEqual(AgentProvider.workbuddyAI.settingsTitle, L10n.text("module.workbuddy-ai.title"),
                       "Settings names the international edition with its own title")
        XCTAssertEqual(AgentProvider.workbuddy.settingsTitle, AgentProvider.workbuddy.displayName)
    }

    func testTheFirstReportConfirmsTheRingAndAMissingFolderRetriesByItself() {
        typealias State = LocalHarnessProgressSetup.State
        XCTAssertEqual(IslandModel.localProgressFollowUp(State(.missingHome), reports: false), .continueSetup,
                       "Once the app has made its folder, setup continues without a retry")
        XCTAssertEqual(IslandModel.localProgressFollowUp(State(.configured, connection: .trusted), reports: true), .markReported)
        XCTAssertNil(IslandModel.localProgressFollowUp(State(.configured, connection: .trusted), reports: false))
        XCTAssertNil(IslandModel.localProgressFollowUp(State(.configured, connection: .trusted, reported: true), reports: true),
                     "Recorded once")
        XCTAssertNil(IslandModel.localProgressFollowUp(State(.settingUp), reports: true), "Only a finished setup is confirmed")
    }

    func testTheRingCardOnboardingNoteAndPanelHintFollowTheModulesThatTrustATool() throws {
        let (model, defaults) = try model()
        var modules = ProviderModules()
        modules.setMode(.enabled, for: .workbuddy); modules.setMode(.enabled, for: .workbuddyAI)
        modules.save(to: defaults)
        model.applySettings(sourceChanged: false)
        XCTAssertNil(model.progressGuide(.claude), "Only a module whose app trusts Pacer's tool has the card")
        XCTAssertNil(model.progressGuide(.workbuddy), "No card before setup reports back")
        XCTAssertFalse(model.progressGuideInfo(.workbuddyAI).isEmpty, "ⓘ still explains the ring while it is off")
        XCTAssertEqual(model.progressOnboardingModules, [.workbuddy, .workbuddyAI],
                       "Before setup reports back, onboarding names every app that will need a step")
        defaults.set(["workbuddy-ai"], forKey: IslandModel.disabledHarnessProgressKey)
        XCTAssertEqual(model.progressOnboardingModules, [.workbuddy], "A ring turned off needs nothing")
        XCTAssertTrue(model.progressGuideHints.isEmpty, "The panel hint waits for a running task")
    }

    func testTheCardRemembersTheConnectorsItOpenedUntilTheAppQuits() throws {
        let (model, _) = try model()
        model.noteOpenedConnectors(.workbuddy)
        model.reportHarnessView(.workbuddy, .customConnectors)
        XCTAssertEqual(Set(model.harnessOpenedConnectors.keys), [.workbuddy], "When the card opened them is kept for the app's log")
        XCTAssertEqual(model.harnessAppViews[.workbuddy], .customConnectors)
        XCTAssertNil(model.harnessAppViews[.workbuddyAI], "Each edition keeps its own page")
        model.forgetHarnessPage(.workbuddy)
        XCTAssertTrue(model.harnessOpenedConnectors.isEmpty, "A quit app starts again on its own page")
        XCTAssertNil(model.harnessAppViews[.workbuddy])
    }

    func testDataFolderWinsOverTheDefault() throws {
        let (model, defaults) = try model()
        let folder = "/private/tmp/pacer-workbuddy-data-" + UUID().uuidString
        defaults.set([AgentProvider.workbuddy.rawValue: folder], forKey: IslandModel.harnessHomesKey)
        XCTAssertEqual(model.localHarnessHome(.workbuddy)?.path, folder)
        defaults.set([AgentProvider.workbuddy.rawValue: ""], forKey: IslandModel.harnessHomesKey)
        XCTAssertNotEqual(model.localHarnessHome(.workbuddy)?.path, "", "An empty folder returns to the default")
    }
}
