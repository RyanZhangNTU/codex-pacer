import XCTest
@testable import PacerCore
@testable import PacerIsland

@MainActor
final class WidthMeasurementTests: XCTestCase {
    func testMeasurementsRelayoutOnlyWhenRoundedContentChanges() async {
        let model = IslandModel(demo: true)
        var layouts = 0
        model.onLayoutChange = { layouts += 1 }
        model.updateMeasuredHeaderWidth(leading: 110.1, trailing: 70.1)
        XCTAssertEqual(layouts, 1)
        model.updateMeasuredHeaderWidth(leading: 110.4, trailing: 70.4)
        XCTAssertEqual(layouts, 1, "Repeated subpoint measurements must not restart the animation")
        model.updateMeasuredHeaderWidth(leading: .nan, trailing: 80)
        model.updateMeasuredHeaderWidth(leading: 0, trailing: 0)
        XCTAssertEqual(layouts, 1)
        model.updateMeasuredHeaderWidth(leading: 40, trailing: 35)
        XCTAssertEqual(layouts, 2, "The header can shrink after activity ends")
        model.updateMeasuredContentWidth(650.2)
        model.updateMeasuredContentWidth(650.4)
        XCTAssertEqual(layouts, 3)
        model.updateMeasuredContentWidth(0)
        XCTAssertEqual(layouts, 4, "Removing all task rows clears their preferred width")
        XCTAssertEqual(model.measuredContentWidth, 0)
        await model.shutdown()
    }
}
