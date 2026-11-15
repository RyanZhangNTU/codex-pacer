import CoreGraphics
import XCTest
@testable import PacerCore
import PacerMacSupport

final class HarnessPointerScanTests: XCTestCase {
    private func button(_ name: String, _ x: CGFloat, _ y: CGFloat) -> MacHarnessPointerScan.Element {
        .init(role: "AXButton", name: name, frame: CGRect(x: x, y: y, width: 60, height: 26))
    }
    private func text(_ name: String, _ x: CGFloat, _ y: CGFloat) -> MacHarnessPointerScan.Element {
        .init(role: "AXStaticText", name: name, frame: CGRect(x: x, y: y, width: 120, height: 16))
    }

    func testTheConnectorsPageShowsCustomConnectorAndNoTrustYet() {
        let result = MacHarnessPointerScan.result([button("专家", 40, 20), button(" 自定义连接器 ", 900, 18), button("信任", 300, 400)])
        XCTAssertEqual(result.view, .connectors)
        XCTAssertEqual(result.customConnector?.minX, 900, "Names are matched without surrounding space")
        XCTAssertNil(result.trust, "Without Pacer's entry, no Trust button is Pacer's")
        XCTAssertEqual(MacHarnessPointerScan.result([button("Custom Connector", 900, 18)]).view, .connectors, "English names count too")
        XCTAssertNil(MacHarnessPointerScan.result([button("连接器", 10, 10)]).view)
    }

    func testTrustIsTheButtonOnPacersOwnEntry() {
        // Two cards side by side and one below; each has its own Trust at its bottom right.
        let elements = [
            text("other_server", 100, 100), button("信任", 300, 160),
            text("pacer_progress", 420, 100), button("信任", 620, 160),
            text("third", 100, 240), button("Trust", 300, 300),
        ]
        let result = MacHarnessPointerScan.result(elements)
        XCTAssertEqual(result.view, .customConnectors, "Pacer's entry means the custom connectors are open")
        XCTAssertEqual(result.trust?.minX, 620)
        // The entry's name can sit inside a longer label.
        let below = MacHarnessPointerScan.result([button("信任", 300, 60), text("pacer_progress · stdio", 100, 100), button("Trust", 300, 160)])
        XCTAssertEqual(below.trust?.minY, 160, "A button above the entry belongs to the card before it")
    }

    func testEmptyFramesAreIgnored() {
        let hidden = MacHarnessPointerScan.Element(role: "AXButton", name: "自定义连接器", frame: .zero)
        XCTAssertNil(MacHarnessPointerScan.result([hidden]).customConnector, "An element without a place can't be pointed at")
    }
}
