import XCTest
@testable import PacerCore
@testable import PacerIsland

@MainActor
final class WidthMeasurementTests: XCTestCase {
    func testMeasurementsRelayoutOnlyWhenRoundedContentChanges() async {
        let model = IslandModel(demo: true)
        var layouts = 0
        model.onLayoutChange = { layouts += 1 }
        model.updateMeasuredCompactWidth(110.1)
        XCTAssertEqual(layouts, 1)
        model.updateMeasuredCompactWidth(110.4)
        XCTAssertEqual(layouts, 1, "Repeated subpoint measurements must not restart the animation")
        model.updateMeasuredCompactWidth(.nan)
        model.updateMeasuredCompactWidth(-1)
        XCTAssertEqual(layouts, 1)
        model.updateMeasuredCompactWidth(40)
        XCTAssertEqual(layouts, 2, "The header can shrink after activity ends")
        model.updateMeasuredContentWidth(650.2)
        model.updateMeasuredContentWidth(650.4)
        XCTAssertEqual(layouts, 3)
        model.updateMeasuredContentWidth(0)
        XCTAssertEqual(layouts, 4, "Removing all task rows clears their preferred width")
        XCTAssertEqual(model.measuredContentWidth, 0)
        await model.shutdown()
    }

    func testApplyingSettingsKeepsTheMeasuredBarWidth() async {
        let name = "WidthMeasurementTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let model = IslandModel(demo: true, defaults: defaults)
        model.updateMeasuredCompactWidth(212)
        defaults.set(false, forKey: "showAppButtons")
        model.applySettings(sourceChanged: false)
        XCTAssertEqual(model.measuredCompactWidth, 212,
            "A setting that leaves the bar unchanged brings no new measurement, so the last one must stay")
        await model.shutdown()
    }
}
