import XCTest
@testable import PacerCore

final class IslandWidthSettingsTests: XCTestCase {
    func testDefaultAndSavedChoicesAcrossPreferencesReloads() throws {
        let name = "pacer-width-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(IslandWidthSettings.load(from: defaults).mode, .adaptive)
        defaults.register(defaults: ["islandWidthMode": IslandWidthSettings.Mode.adaptive.rawValue])
        // Existing releases have display/appearance choices, but no width mode.
        defaults.set("notch", forKey: "islandDisplayMode")
        defaults.set(false, forKey: "floatingIsland")
        defaults.set(31.0, forKey: "glassCornerRadius")
        XCTAssertEqual(IslandWidthSettings.load(from: defaults).mode, .adaptive,
                       "An upgrade must start in Adaptive regardless of the old display mode")
        defaults.set("fixed", forKey: "islandWidthMode")
        defaults.set(420, forKey: "collapsedIslandWidth")
        defaults.set(620, forKey: "expandedIslandWidth")
        XCTAssertEqual(IslandWidthSettings.load(from: defaults).width, 620)
        let fixed = IslandWidthSettings(mode: .fixed, width: 620)
        fixed.save(to: defaults)
        XCTAssertNil(defaults.object(forKey: "collapsedIslandWidth"))
        XCTAssertNil(defaults.object(forKey: "expandedIslandWidth"))
        let reopened = try XCTUnwrap(UserDefaults(suiteName: name))
        XCTAssertEqual(IslandWidthSettings.load(from: reopened), fixed)
        XCTAssertEqual(defaults.string(forKey: "islandDisplayMode"), "notch")
        XCTAssertEqual(defaults.double(forKey: "glassCornerRadius"), 31)
        var adaptive = fixed
        adaptive.mode = .adaptive
        adaptive.save(to: defaults)
        XCTAssertEqual(IslandWidthSettings.load(from: reopened), adaptive,
                       "Changing mode preserves the user's specified width")
        defaults.set("future-mode", forKey: "islandWidthMode")
        XCTAssertEqual(IslandWidthSettings.load(from: reopened).mode, .adaptive)
    }

    func testInvalidPreferencesCannotProduceAnUnboundedOrInvertedPanel() {
        XCTAssertEqual(IslandWidthSettings(mode: .fixed, width: .nan).normalized.width, 480)
        XCTAssertEqual(IslandWidthSettings(mode: .fixed, width: .infinity).normalized.width, 480)
        XCTAssertEqual(IslandWidthSettings(mode: .fixed, width: -100).normalized.width, 360)
        XCTAssertEqual(IslandWidthSettings(mode: .fixed, width: 5000).normalized.width, 900)
        XCTAssertEqual(IslandWidthSettings(width: 479.8).normalized, IslandWidthSettings(width: 480))
    }

    func testAdaptiveWidthTracksContentAndKeepsCameraWingsEqual() {
        let adaptive = IslandWidthSettings()
        let idle = adaptive.desiredWidth(expanded: false, notchWidth: 0, leading: 40, trailing: 35)
        let active = adaptive.desiredWidth(expanded: false, notchWidth: 0, leading: 180, trailing: 85)
        XCTAssertEqual(idle, 180)
        XCTAssertGreaterThan(active, idle)
        XCTAssertGreaterThanOrEqual(active, 180 + 85 + 52)
        for notch in [184.0, 185.0, 205.0] {
            let desired = adaptive.desiredWidth(expanded: false, notchWidth: notch, leading: 180, trailing: 85)
            let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
            let frame = IslandGeometry.frame(screen: screen, visible: screen, notchWidth: notch,
                topHeight: 37, expanded: false, attached: true, desiredWidth: desired)
            let wing = (frame.width - 42 - notch - 8) / 2
            XCTAssertGreaterThanOrEqual(wing, 180, "Quantizing cannot clip the wider header wing")
            XCTAssertEqual(frame.midX, screen.midX)
        }
        XCTAssertEqual(adaptive.desiredWidth(expanded: true, notchWidth: 0, leading: 40, trailing: 35), 404)
        XCTAssertEqual(adaptive.desiredWidth(expanded: true, notchWidth: 0, leading: 40, trailing: 35,
            contentWidth: 420), 420, "Rows between the bounds set the expanded width")
        XCTAssertEqual(adaptive.desiredWidth(expanded: true, notchWidth: 0, leading: 40, trailing: 35,
            contentWidth: 580), 580)
        XCTAssertEqual(adaptive.desiredWidth(expanded: true, notchWidth: 0, leading: 40, trailing: 35,
            contentWidth: 5000), 680)
    }

    func testSpecifiedWidthDoesNotFollowContentButReservesHardwareSpace() {
        let fixed = IslandWidthSettings(mode: .fixed, width: 620)
        for leading in [40.0, 180.0, 240.0] {
            XCTAssertEqual(fixed.desiredWidth(expanded: false, notchWidth: 0, leading: leading, trailing: 80), 620)
            XCTAssertEqual(fixed.desiredWidth(expanded: true, notchWidth: 185, leading: leading, trailing: 80,
                contentWidth: 900), 620)
        }
        let narrow = IslandWidthSettings(mode: .fixed, width: 360)
        XCTAssertGreaterThanOrEqual(narrow.desiredWidth(expanded: false, notchWidth: 205, leading: 80, trailing: 60), 405)
    }

    func testResizingAndReversalKeepScreenAnchorsAndQuantizedEndpoints() {
        for attached in [false, true] {
            let screen = CGRect(x: -1727, y: -120, width: 1727, height: 1117)
            let visible = screen.insetBy(dx: 0, dy: 30)
            let notch: CGFloat = attached ? 185 : 0
            let small = IslandGeometry.frame(screen: screen, visible: visible, notchWidth: notch,
                topHeight: 38, expanded: false, attached: attached, desiredWidth: 421)
            let wide = IslandGeometry.frame(screen: screen, visible: visible, notchWidth: notch,
                topHeight: 38, expanded: false, attached: attached, desiredWidth: 599)
            let clamped = IslandGeometry.frame(screen: screen, visible: visible, notchWidth: notch,
                topHeight: 38, expanded: true, attached: attached, desiredWidth: 5000)
            XCTAssertLessThanOrEqual(clamped.width, screen.width - 24)
            let top = attached ? screen.maxY : visible.maxY - 10
            var transition = IslandTransition(from: .resting(at: small, expanded: false, hasBlackHeader: attached),
                to: wide, opening: false, hasBlackHeader: attached, start: 0)
            let reversed = transition.sample(at: 0.08)
            XCTAssertGreaterThan(reversed.frame.width, small.width)
            transition = IslandTransition(from: reversed, to: small, opening: false, hasBlackHeader: attached, start: 0.08)
            for tick in 1...240 {
                let sample = transition.sample(at: 0.08 + Double(tick) / 120)
                let frame = IslandGeometry.windowFrame(sample.frame)
                XCTAssertEqual(frame.maxY, top)
                XCTAssertEqual(frame.midX, screen.midX)
                if sample.finished {
                    XCTAssertEqual(frame, small)
                    break
                }
                if tick == 240 { XCTFail("Width reversal failed to settle") }
            }
        }
    }
}
