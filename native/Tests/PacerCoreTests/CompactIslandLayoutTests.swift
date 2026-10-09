import XCTest
@testable import PacerCore

final class CompactIslandLayoutTests: XCTestCase {
    func testMovesPreserveOneComponentAndSupportPositionsAndInsertion() {
        var layout = CompactIslandLayout.standard
        layout.move(.tps, to: .trailing)
        layout.move(.status, to: .trailing, before: .tps)
        XCTAssertEqual(layout.trailing.suffix(2), [.status, .tps])
        XCTAssertEqual(layout.leading, [.statusIcon])
        layout.move(.tps, to: .trailing, before: .quotaMetric)
        XCTAssertEqual(layout.leading, [.statusIcon])
        XCTAssertEqual(layout.trailing, [.quotaWarning, .tps, .quotaMetric, .quotaWindow, .freshness, .status])
        let previous = layout
        layout.move(.status, to: .trailing, before: .status)
        XCTAssertEqual(layout, previous, "Dropping on itself must not lose the dragged component")
        layout.shift(.tps, by: -1)
        XCTAssertEqual(layout.trailing.first, .tps)
        layout.shift(.tps, by: -1)
        XCTAssertEqual(layout.trailing.first, .tps, "Keyboard reordering stops at the boundary")
        layout.shift(.tps, by: 100)
        XCTAssertEqual(layout.trailing.last, .tps)
        layout.hide(.status)
        XCTAssertFalse(layout.components.contains(.status))
        XCTAssertTrue(layout.components.contains(.tps))
    }
    func testDefaultsAndCustomLayoutPersistWithoutChangingOtherPreferences() throws {
        let name = "CompactLayoutTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("fixed", forKey: "islandWidthMode")
        defaults.set(610, forKey: "specifiedIslandWidth")
        XCTAssertEqual(CompactIslandLayout.load(from: defaults), .standard)
        XCTAssertNil(defaults.data(forKey: CompactIslandLayout.defaultsKey), "A new or upgraded profile must not write settings on load")
        var layout = CompactIslandLayout(leading: [.tps], trailing: [.quotaMetric, .settings])
        layout.save(to: defaults)
        XCTAssertEqual(CompactIslandLayout.load(from: defaults), layout)
        XCTAssertEqual(IslandWidthSettings.load(from: defaults), .init(mode: .fixed, width: 610))
        for component in layout.components { layout.hide(component) }
        layout.save(to: defaults)
        XCTAssertTrue(CompactIslandLayout.load(from: defaults).components.isEmpty, "Hiding everything is intentional")
        for invalid in [Data("broken".utf8), Data(#"{"version":3,"leading":[],"trailing":[]}"#.utf8), Data(repeating: 0, count: 8193)] {
            defaults.set(invalid, forKey: CompactIslandLayout.defaultsKey)
            XCTAssertEqual(CompactIslandLayout.load(from: defaults), .standard)
        }
    }
    func testLegacyCenterMigrationPreservesChoicesWithoutWritingUntilSave() throws {
        let data = Data(#"{"version":1,"leading":["tps","futureMetric","status"],"center":["tps","settings"],"trailing":["status"]}"#.utf8)
        let layout = try JSONDecoder().decode(CompactIslandLayout.self, from: data).normalized
        XCTAssertEqual(layout.leading, [.tps, .status, .settings])
        XCTAssertTrue(layout.trailing.isEmpty)
        let name = "CompactLayoutMigrationTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(data, forKey: CompactIslandLayout.defaultsKey)
        XCTAssertEqual(CompactIslandLayout.load(from: defaults), layout)
        XCTAssertEqual(defaults.data(forKey: CompactIslandLayout.defaultsKey), data)
        layout.save(to: defaults)
        let saved = try XCTUnwrap(defaults.data(forKey: CompactIslandLayout.defaultsKey))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, 2)
        XCTAssertNil(object["center"])
        XCTAssertEqual(CompactIslandLayout.load(from: defaults), layout)
    }
    func testCameraClearanceAndAdaptiveShrinkingRespectExpandedAndFixedWidths() {
        let widths = IslandWidthSettings()
        let full = widths.desiredWidth(expanded: false, notchWidth: 0, leading: 300, trailing: 80, headerWidth: 420)
        let compact = widths.desiredWidth(expanded: false, notchWidth: 0, leading: 300, trailing: 80, headerWidth: 112)
        XCTAssertEqual(compact, 114)
        XCTAssertLessThan(compact, full, "Hidden content must not retain a previously measured wide header")
        XCTAssertEqual(widths.desiredWidth(expanded: false, notchWidth: 180, leading: 0, trailing: 0, headerWidth: 218), 240)
        XCTAssertGreaterThanOrEqual(widths.desiredWidth(expanded: true, notchWidth: 0, leading: 0, trailing: 0, headerWidth: 112), 440)
        XCTAssertEqual(IslandWidthSettings(mode: .fixed, width: 600).desiredWidth(expanded: false,
            notchWidth: 0, leading: 0, trailing: 0, headerWidth: 112), 600)
    }
}
