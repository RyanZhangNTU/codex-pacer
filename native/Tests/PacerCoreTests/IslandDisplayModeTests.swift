import XCTest
@testable import PacerCore

final class IslandDisplayModeTests: XCTestCase {
    func testOldPreferencesKeepTheirBehaviorAndExplicitModeTakesPrecedence() throws {
        let name = "pacer-display-mode-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(IslandDisplayMode.load(from: defaults), .automatic)
        defaults.set(true, forKey: "floatingIsland")
        XCTAssertEqual(IslandDisplayMode.load(from: defaults), .floating)
        defaults.set(false, forKey: "floatingIsland")
        XCTAssertEqual(IslandDisplayMode.load(from: defaults), .automatic)

        IslandDisplayMode.notch.save(to: defaults)
        XCTAssertEqual(IslandDisplayMode.load(from: defaults), .notch)
        XCTAssertFalse(defaults.bool(forKey: "floatingIsland"))
        IslandDisplayMode.floating.save(to: defaults)
        XCTAssertEqual(IslandDisplayMode.load(from: defaults), .floating)
        XCTAssertTrue(defaults.bool(forKey: "floatingIsland"))
        defaults.set("automatic", forKey: "islandDisplayMode")
        XCTAssertEqual(IslandDisplayMode.load(from: defaults), .automatic)
        defaults.set("unknown", forKey: "islandDisplayMode")
        XCTAssertEqual(IslandDisplayMode.load(from: defaults), .floating)
    }

    func testAutomaticModeFollowsHardwareAndFloatingModeAlwaysClearsTheGap() {
        XCTAssertEqual(IslandDisplayMode.automatic.layout(safeAreaTop: 0, hardwareNotchWidth: 0),
                       IslandDisplayMode.floating.layout(safeAreaTop: 0, hardwareNotchWidth: 0))
        XCTAssertEqual(IslandDisplayMode.automatic.layout(safeAreaTop: 37, hardwareNotchWidth: 185),
                       IslandDisplayMode.notch.layout(safeAreaTop: 37, hardwareNotchWidth: 185))
        let floating = IslandDisplayMode.floating.layout(safeAreaTop: 37, hardwareNotchWidth: 185)
        XCTAssertFalse(floating.attached)
        XCTAssertEqual(floating.notchWidth, 0)
        XCTAssertEqual(floating.topHeight, 38)
    }

    func testNotchModeReservesOnlyRealHardwareAndAttachesWithoutIt() {
        let virtual = IslandDisplayMode.notch.layout(safeAreaTop: 0, hardwareNotchWidth: 0)
        XCTAssertTrue(virtual.attached)
        XCTAssertEqual(virtual.notchWidth, 0)
        XCTAssertEqual(virtual.topHeight, 32)
        let hardware = IslandDisplayMode.notch.layout(safeAreaTop: 37, hardwareNotchWidth: 185)
        XCTAssertTrue(hardware.attached)
        XCTAssertEqual(hardware.notchWidth, 185)
        XCTAssertEqual(hardware.topHeight, 37)
        let unmeasured = IslandDisplayMode.automatic.layout(safeAreaTop: 37, hardwareNotchWidth: 0)
        XCTAssertTrue(unmeasured.attached)
        XCTAssertEqual(unmeasured.notchWidth, 0)
    }

    func testNotchAndFloatingAnchorsOnOneAndTwoTimesExternalDisplays() {
        for scale in [1.0, 2.0] {
            let screen = CGRect(x: -1920 / scale, y: -120, width: 1920 / scale, height: 1080 / scale)
            let visible = CGRect(x: screen.minX, y: screen.minY + 48,
                width: screen.width, height: screen.height - 48 - 24)
            for mode in [IslandDisplayMode.notch, .floating] {
                let layout = mode.layout(safeAreaTop: 0, hardwareNotchWidth: 0)
                var frames: [CGRect] = []
                for expanded in [false, true] {
                    let frame = IslandGeometry.frame(screen: screen, visible: visible,
                        notchWidth: layout.notchWidth, topHeight: layout.topHeight,
                        expanded: expanded, attached: layout.attached)
                    XCTAssertEqual(frame.maxY, mode == .notch ? screen.maxY : visible.maxY - 10)
                    XCTAssertEqual(frame.midX, screen.midX)
                    XCTAssertGreaterThanOrEqual(frame.minX, screen.minX)
                    XCTAssertLessThanOrEqual(frame.maxX, screen.maxX)
                    for edge in [frame.minX, frame.minY, frame.maxX, frame.maxY] {
                        XCTAssertEqual(edge, edge.rounded())
                    }
                    frames.append(frame)
                }
                XCTAssertEqual(frames[0].width, 300)
                XCTAssertEqual(frames[0].maxY, frames[1].maxY)
            }
        }
    }

    func testForcedNotchCollapseKeepsExternalDisplayTopFixed() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let visible = CGRect(x: 0, y: 48, width: 1920, height: 1008)
        let layout = IslandDisplayMode.notch.layout(safeAreaTop: 0, hardwareNotchWidth: 0)
        let folded = IslandGeometry.frame(screen: screen, visible: visible, notchWidth: layout.notchWidth,
            topHeight: layout.topHeight, expanded: false, attached: layout.attached)
        let expanded = IslandGeometry.frame(screen: screen, visible: visible, notchWidth: layout.notchWidth,
            topHeight: layout.topHeight, expanded: true, attached: layout.attached)
        var transition = IslandTransition(from: .resting(at: expanded, expanded: true, hasBlackHeader: true),
            to: folded, opening: false, hasBlackHeader: true, start: 0)
        var previous = expanded
        for tick in 1...120 {
            let sample = transition.sample(at: Double(tick) / 120)
            let displayed = IslandGeometry.windowFrame(sample.frame)
            XCTAssertEqual(displayed.maxY, screen.maxY)
            if sample.finished {
                XCTAssertEqual(previous, folded)
                XCTAssertEqual(displayed, folded)
                return
            }
            previous = displayed
        }
        XCTFail("Forced notch collapse did not settle")
    }
}
