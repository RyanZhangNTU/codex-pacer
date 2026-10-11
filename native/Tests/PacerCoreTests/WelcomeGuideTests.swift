import XCTest
@testable import PacerCore

final class WelcomeGuideTests: XCTestCase {
    func testGuideShowsOncePerMajorLineForFreshInstallsAndUpgrades() throws {
        let name = "WelcomeGuideTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertTrue(WelcomeGuide.shouldShow(defaults: defaults), "A fresh install sees the guide")
        defaults.set(2, forKey: WelcomeGuide.defaultsKey)
        XCTAssertTrue(WelcomeGuide.shouldShow(defaults: defaults), "An upgrade from an earlier major line sees the guide")
        WelcomeGuide.markShown(defaults: defaults)
        XCTAssertFalse(WelcomeGuide.shouldShow(defaults: defaults), "Later launches and updates within 3.x stay quiet")
        XCTAssertEqual(defaults.integer(forKey: WelcomeGuide.defaultsKey), WelcomeGuide.currentMajor)
        defaults.set(WelcomeGuide.currentMajor + 1, forKey: WelcomeGuide.defaultsKey)
        XCTAssertFalse(WelcomeGuide.shouldShow(defaults: defaults), "Downgrading never replays a newer guide")
    }
}
