import XCTest
@testable import PacerCore

final class IslandWindowFrameTests: XCTestCase {
    private let folded = CGRect(x: 714, y: 1036, width: 300, height: 38)
    private let expanded = CGRect(x: 644, y: 486, width: 440, height: 588)

    func testSubpointRemainderDoesNotHoldCapsuleOnePointTooLarge() {
        // Captured from the real panel immediately before its final sample:
        // AppKit displayed this as (713, 1035, 301, 39) for the old code.
        let last = CGRect(x: 713.9972616991021, y: 1035.9784847786595,
                          width: 300.0054766017958, height: 38.021515221340564)
        XCTAssertEqual(IslandGeometry.windowFrame(last), folded)
        XCTAssertEqual(IslandGeometry.windowFrame(folded), folded)
    }

    func testIntegralWindowEdgesKeepTheTopAndCenterAnchored() {
        for center in [-960.0, -959.5, 864.0, 864.5] {
            for step in 0...300 {
                let width = 300 + Double(step) / 3
                let height = 38 + Double(step) / 7
                let frame = CGRect(x: center - width / 2, y: 1074 - height, width: width, height: height)
                let displayed = IslandGeometry.windowFrame(frame)
                XCTAssertEqual(displayed.midX, center)
                XCTAssertEqual(displayed.maxY, 1074)
                for edge in [displayed.minX, displayed.maxX, displayed.minY, displayed.maxY] {
                    XCTAssertEqual(edge, edge.rounded())
                }
                XCTAssertLessThanOrEqual(abs(displayed.width - width), 1)
                XCTAssertLessThanOrEqual(abs(displayed.height - height), 0.5)
            }
        }
    }

    func testFloatingCollapseHasNoDelayedFinalWindowResize() {
        for refreshRate in [30.0, 60.0, 120.0] {
            let motion = IslandMotion(from: .resting(at: expanded, expanded: true),
                                      to: folded, opening: false, start: 0)
            var previous = expanded
            var changes: [Double] = []
            var finished = false
            for tick in 1...Int(refreshRate) {
                let time = Double(tick) / refreshRate
                let sample = motion.sample(at: time)
                let displayed = IslandGeometry.windowFrame(sample.frame)
                if sample.finished {
                    XCTAssertEqual(previous, folded, "The last spring tick must not resize the window")
                    XCTAssertGreaterThan(time - (changes.last ?? 0), 0.06)
                    finished = true
                    break
                }
                if displayed != previous { changes.append(time) }
                previous = displayed
            }
            XCTAssertTrue(finished)
            XCTAssertGreaterThan(changes.count, 2)
            if changes.count >= 2 {
                // The old outward rounding held 301 x 39 for about 170 ms,
                // then changed both position and size on the finishing tick.
                XCTAssertLessThanOrEqual(changes[changes.count - 1] - changes[changes.count - 2], 0.084)
            }
        }
    }

    func testOddNotchWidthUsesTheSameEndpointThroughoutCollapse() {
        let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let closed = IslandGeometry.frame(screen: screen, visible: screen, notchWidth: 185,
                                          topHeight: 32, expanded: false, attached: true)
        let open = IslandGeometry.frame(screen: screen, visible: screen, notchWidth: 185,
                                        topHeight: 32, expanded: true, attached: true, contentHeight: 550)
        XCTAssertEqual(closed, CGRect(x: 622, y: 1085, width: 484, height: 32))
        let motion = IslandMotion(from: .resting(at: open, expanded: true), to: closed, opening: false, start: 0)
        var previous = open
        var lastChange = 0.0
        for tick in 1...120 {
            let time = Double(tick) / 120
            let sample = motion.sample(at: time)
            let displayed = IslandGeometry.windowFrame(sample.frame)
            if sample.finished {
                // The native trace previously changed from 426 to 424 here,
                // about 135 ms after the height had stopped changing.
                XCTAssertEqual(previous, closed)
                XCTAssertEqual(displayed, closed)
                XCTAssertGreaterThan(time - lastChange, 0.06)
                return
            }
            if displayed != previous { lastChange = time }
            previous = displayed
        }
        XCTFail("Notch collapse did not settle")
    }

    func testBothModesFinishWithoutAResizeForOddAndEvenDisplayWidths() {
        for screenWidth in [1727.0, 1728.0] {
            let screen = CGRect(x: 0, y: 0, width: screenWidth, height: 1117)
            for notchWidth in [0.0, 184.0, 185.0, 187.0, 205.0] {
                let attached = notchWidth > 0
                let topHeight = attached ? 32.0 : 38.0
                let closed = IslandGeometry.frame(screen: screen, visible: screen, notchWidth: notchWidth,
                                                  topHeight: topHeight, expanded: false, attached: attached)
                let open = IslandGeometry.frame(screen: screen, visible: screen, notchWidth: notchWidth,
                                                topHeight: topHeight, expanded: true, attached: attached)
                for opening in [true, false] {
                    let target = opening ? open : closed
                    XCTAssertEqual(target, IslandGeometry.windowFrame(target))
                    for refreshRate in [30.0, 60.0, 120.0] {
                        let motion = IslandMotion(from: .resting(at: opening ? closed : open, expanded: !opening),
                                                  to: target, opening: opening, start: 0)
                        var previous = opening ? closed : open
                        var finished = false
                        for tick in 1...Int(refreshRate) {
                            let sample = motion.sample(at: Double(tick) / refreshRate)
                            let displayed = IslandGeometry.windowFrame(sample.frame)
                            XCTAssertEqual(displayed.midX, screen.midX)
                            XCTAssertEqual(displayed.maxY, target.maxY)
                            if sample.finished {
                                XCTAssertEqual(previous, target, "Final tick changed size: screen=\(screenWidth), notch=\(notchWidth)")
                                finished = true
                                break
                            }
                            previous = displayed
                        }
                        XCTAssertTrue(finished)
                    }
                }
            }
        }
    }
}
