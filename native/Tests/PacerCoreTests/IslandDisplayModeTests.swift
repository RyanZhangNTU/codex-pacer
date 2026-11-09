import XCTest
@testable import PacerCore

final class IslandDisplayModeTests: XCTestCase {
    func testOldPreferencesKeepTheirBehaviorAndExplicitModeTakesPrecedence() throws {
        let name = testDefaultsName("pacer-display-mode-test")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { removeTestDefaults(name) }
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
        XCTAssertEqual(floating.topHeight, 36)
        XCTAssertEqual(floating.stripWidth, 32); XCTAssertTrue(floating.sizeAdjustable)
    }

    func testEveryBarButOneOnAHardwareNotchFollowsTheSavedSize() {
        for (size, height, strip) in [(CompactBarSize.small, 32.0, 28.0), (.standard, 36, 32), (.large, 42, 37), (.extraLarge, 48, 43)] {
            let floating = IslandDisplayMode.floating.layout(safeAreaTop: 37, hardwareNotchWidth: 185, size: size)
            XCTAssertEqual(floating.topHeight, CGFloat(height)); XCTAssertEqual(floating.stripWidth, CGFloat(strip))
            let virtual = IslandDisplayMode.notch.layout(safeAreaTop: 0, hardwareNotchWidth: 0, size: size)
            XCTAssertEqual(virtual.topHeight, CGFloat(height)); XCTAssertTrue(virtual.sizeAdjustable)
            // The notch fixes the height; the setting is unavailable there.
            let hardware = IslandDisplayMode.notch.layout(safeAreaTop: 37, hardwareNotchWidth: 185, size: size)
            XCTAssertEqual(hardware.topHeight, 37); XCTAssertFalse(hardware.sizeAdjustable)
            XCTAssertEqual(IslandDisplayMode.automatic.layout(safeAreaTop: 37, hardwareNotchWidth: 0, size: size).topHeight, 37)
            XCTAssertEqual(size.effective(attached: true, hardwareNotch: true), .standard)
            XCTAssertEqual(size.effective(attached: false, hardwareNotch: true), size)
        }
    }

    func testNotchModeReservesOnlyRealHardwareAndAttachesWithoutIt() {
        let virtual = IslandDisplayMode.notch.layout(safeAreaTop: 0, hardwareNotchWidth: 0)
        XCTAssertTrue(virtual.attached)
        XCTAssertEqual(virtual.notchWidth, 0)
        XCTAssertEqual(virtual.topHeight, 36)
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
                    XCTAssertGreaterThanOrEqual(frame.minY, visible.minY + 8)
                    for edge in [frame.minX, frame.minY, frame.maxX, frame.maxY] {
                        XCTAssertEqual(edge, edge.rounded())
                    }
                    frames.append(frame)
                }
                XCTAssertEqual(frames[0].width, mode == .notch ? 480 : 300)
                XCTAssertEqual(frames[0].maxY, frames[1].maxY)
            }
        }
    }

    func testSmallDisplayClampsExpandedFrame() {
        let screen = CGRect(x: 0, y: 0, width: 400, height: 280)
        for mode in [IslandDisplayMode.notch, .floating] {
            let layout = mode.layout(safeAreaTop: 0, hardwareNotchWidth: 0)
            let frame = IslandGeometry.frame(screen: screen, visible: screen, notchWidth: layout.notchWidth,
                topHeight: layout.topHeight, expanded: true, attached: layout.attached)
            XCTAssertEqual(frame.midX, screen.midX)
            XCTAssertEqual(frame.maxY, mode == .notch ? screen.maxY : screen.maxY - 10)
            XCTAssertGreaterThanOrEqual(frame.minY, screen.minY + 8)
            XCTAssertLessThanOrEqual(frame.width, screen.width - 24)
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
