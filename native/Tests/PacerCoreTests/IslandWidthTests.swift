import XCTest
@testable import PacerCore

final class IslandWidthTests: XCTestCase {
    func testAdaptiveWidthTracksContentAndKeepsCameraWingsEqual() {
        let idle = IslandWidth.desired(expanded: false, notchWidth: 0, leading: 40, trailing: 35)
        let active = IslandWidth.desired(expanded: false, notchWidth: 0, leading: 180, trailing: 85)
        XCTAssertEqual(idle, 180)
        XCTAssertGreaterThan(active, idle)
        XCTAssertGreaterThanOrEqual(active, 180 + 85 + 52)
        for notch in [184.0, 185.0, 205.0] {
            let desired = IslandWidth.desired(expanded: false, notchWidth: notch, leading: 180, trailing: 85)
            let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
            let frame = IslandGeometry.frame(screen: screen, visible: screen, notchWidth: notch,
                topHeight: 37, expanded: false, attached: true, desiredWidth: desired)
            let wing = (frame.width - 42 - notch - 8) / 2
            XCTAssertGreaterThanOrEqual(wing, 180, "Quantizing cannot clip the wider header wing")
            XCTAssertEqual(frame.midX, screen.midX)
        }
        XCTAssertEqual(IslandWidth.desired(expanded: true, notchWidth: 0, leading: 40, trailing: 35), 404)
        XCTAssertEqual(IslandWidth.desired(expanded: true, notchWidth: 0, leading: 40, trailing: 35,
            contentWidth: 420), 420, "Rows between the bounds set the expanded width")
        XCTAssertEqual(IslandWidth.desired(expanded: true, notchWidth: 0, leading: 40, trailing: 35,
            contentWidth: 580), 580)
        XCTAssertEqual(IslandWidth.desired(expanded: true, notchWidth: 0, leading: 40, trailing: 35,
            contentWidth: 5000), 680)
        let notched = IslandWidth.desired(expanded: false, notchWidth: 185, leading: 0, trailing: 0, headerWidth: 520)
        XCTAssertEqual(IslandWidth.desired(expanded: true, notchWidth: 185, leading: 0, trailing: 0, headerWidth: 520), notched,
            "The expanded panel is never narrower than a wide bar around the camera")
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
