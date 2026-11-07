import XCTest
@testable import PacerIsland

final class MainWindowPreferenceTests: XCTestCase {
    private func defaults() -> (UserDefaults, String) {
        let name = "MainWindowPreferenceTests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    func testStoredPagesFromTheSettingsWindowOpenWhereTheirContentMoved() {
        let (defaults, name) = defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(SettingsPane.load(from: defaults), .overview, "A first open lands on Overview")
        let moved: [String: SettingsPane] = ["connections": .remote, "reminders": .notifications,
                                             "whatsNew": .about, "help": .about]
        for (stored, pane) in moved {
            defaults.set(stored, forKey: SettingsPane.defaultsKey)
            XCTAssertEqual(SettingsPane.load(from: defaults), pane, stored)
        }
        for pane in SettingsPane.allCases {
            defaults.set(pane.rawValue, forKey: SettingsPane.defaultsKey)
            XCTAssertEqual(SettingsPane.load(from: defaults), pane, "Current pages reopen as saved")
        }
        defaults.set("removed", forKey: SettingsPane.defaultsKey)
        XCTAssertEqual(SettingsPane.load(from: defaults), .overview)
        XCTAssertEqual(Set(SettingsPane.groups.joined()).union([.about, .support]), Set(SettingsPane.allCases),
            "Every page is reachable from the sidebar's groups or footer")
    }

    func testAboutKeepsTheHelpTabForAnOldHelpPage() {
        let (defaults, name) = defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(AboutTab.load(from: defaults), .whatsNew)
        defaults.set("help", forKey: SettingsPane.defaultsKey)
        XCTAssertEqual(AboutTab.load(from: defaults), .help, "The old Help page opens on its tab")
        defaults.set(AboutTab.whatsNew.rawValue, forKey: AboutTab.defaultsKey)
        XCTAssertEqual(AboutTab.load(from: defaults), .whatsNew, "A chosen tab wins over the old page")
    }

    func testDockIconFollowsTheWindowOnlyByDefault() {
        let (defaults, name) = defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(DockIconPreference.load(from: defaults), .whileOpen)
        XCTAssertEqual(DockIconPreference.allCases.map { [$0.showsIcon(windowOpen: false), $0.showsIcon(windowOpen: true)] },
                       [[false, true], [true, true], [false, false]])
        DockIconPreference.never.save(to: defaults)
        XCTAssertEqual(DockIconPreference.load(from: defaults), .never)
        defaults.set("removed", forKey: DockIconPreference.defaultsKey)
        XCTAssertEqual(DockIconPreference.load(from: defaults), .whileOpen)
    }
}
