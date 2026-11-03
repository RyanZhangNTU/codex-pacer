import ImageIO
import XCTest
@testable import PacerCore

final class ProjectSupportMacTests: XCTestCase {
    private func query(_ url: URL) throws -> [String: String] {
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }




    func testTheWeChatCodeShipsLargeEnoughToScan() throws {
        let code = try XCTUnwrap(ProjectSupport.codes().first { $0.titleKey == "support.code.wechat" })
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(code.image as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        // Shown at 220 points, so it needs at least twice that on a Retina display.
        XCTAssertGreaterThanOrEqual(min(image.width, image.height), 440)
        XCTAssertEqual(image.width, image.height)
    }


}
