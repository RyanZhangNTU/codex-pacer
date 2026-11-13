import XCTest
import PacerCore
@testable import PacerIsland
import PacerTestSupport

final class MainWindowPreferenceTests: XCTestCase {
    private func defaults() -> (UserDefaults, String) {
        let name = testDefaultsName("main-window-preferences")
        return (UserDefaults(suiteName: name)!, name)
    }

    func testStoredPagesFromTheSettingsWindowOpenWhereTheirContentMoved() throws {
        let (defaults, name) = defaults()
        defer { removeTestDefaults(name) }
        XCTAssertEqual(SettingsPane.load(from: defaults), .overview, "A first open lands on Overview")
        let moved: [String: SettingsPane] = ["connections": .remote, "reminders": .notifications,
                                             "whatsNew": .about, "help": .about]
        for (stored, pane) in moved {
            defaults.set(stored, forKey: SettingsPane.defaultsKey)
            XCTAssertEqual(SettingsPane.load(from: defaults), pane, stored)
        }
        let workBuddy = try XCTUnwrap(AgentProvider(rawValue: "workbuddy"))
        let localProviders = [workBuddy]
        let pages = SettingsPane.pages(localProviders: localProviders)
        for pane in pages {
            defaults.set(pane.rawValue, forKey: SettingsPane.defaultsKey)
            XCTAssertEqual(SettingsPane.load(from: defaults), pane, "Current pages reopen as saved")
        }
        defaults.set("removed", forKey: SettingsPane.defaultsKey)
        XCTAssertEqual(SettingsPane.load(from: defaults), .overview)
        XCTAssertEqual(SettingsPane.groups(localProviders: localProviders)[1], [.codex, .claude, .deepseek, SettingsPane(provider: workBuddy), .remote])
        XCTAssertFalse(SettingsPane.pages(localProviders: []).contains(SettingsPane(provider: workBuddy)))
    }

    func testAboutKeepsTheHelpTabForAnOldHelpPage() {
        let (defaults, name) = defaults()
        defer { removeTestDefaults(name) }
        XCTAssertEqual(AboutTab.load(from: defaults), .whatsNew)
        defaults.set("help", forKey: SettingsPane.defaultsKey)
        XCTAssertEqual(AboutTab.load(from: defaults), .help, "The old Help page opens on its tab")
        defaults.set(AboutTab.whatsNew.rawValue, forKey: AboutTab.defaultsKey)
        XCTAssertEqual(AboutTab.load(from: defaults), .whatsNew, "A chosen tab wins over the old page")
    }

    func testHighlightLinksOpenThePageTheyIntroduce() {
        let links = WhatsNew.releases.flatMap(\.items).compactMap { item in item.control?.settingsPane.map { (item.titleKey, $0) } }
        XCTAssertEqual(links.map(\.0), ["whats_new.arrange_items", "whats_new.bar_upgrade", "whats_new.fresh_look"])
        XCTAssertEqual(links.map(\.1), [.expandedPanel, .collapsedBar, .appearance])
        for control: WhatsNew.Item.Control in [.openAtLogin, .showEmbeddedSessions, .showAppButtons] {
            XCTAssertNil(control.settingsPane, "A switch stays in place")
        }
    }

    func testDockIconFollowsTheWindowOnlyByDefault() {
        let (defaults, name) = defaults()
        defer { removeTestDefaults(name) }
        XCTAssertEqual(DockIconPreference.load(from: defaults), .whileOpen)
        XCTAssertEqual(DockIconPreference.allCases.map { [$0.showsIcon(windowOpen: false), $0.showsIcon(windowOpen: true)] },
                       [[false, true], [true, true], [false, false]])
        DockIconPreference.never.save(to: defaults)
        XCTAssertEqual(DockIconPreference.load(from: defaults), .never)
        defaults.set("removed", forKey: DockIconPreference.defaultsKey)
        XCTAssertEqual(DockIconPreference.load(from: defaults), .whileOpen)
    }
}
