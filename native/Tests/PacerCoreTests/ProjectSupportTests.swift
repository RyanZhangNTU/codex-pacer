import ImageIO
import XCTest
@testable import PacerCore

final class ProjectSupportTests: XCTestCase {
    private func query(_ url: URL) throws -> [String: String] {
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    func testStarGoesThroughGitHubSignInAndReturnsToTheProject() throws {
        XCTAssertEqual(ProjectSupport.star.host, "github.com")
        XCTAssertEqual(ProjectSupport.star.path, "/login")
        XCTAssertEqual(try query(ProjectSupport.star)["return_to"], ProjectSupport.repository.path)
        XCTAssertEqual(ProjectSupport.repository.absoluteString, "https://github.com/RyanZhangNTU/codex-pacer")
    }

    func testFeedbackOpensTheMatchingIssueForm() throws {
        for (url, template) in [(ProjectSupport.featureRequest, "feature_request.yml"), (ProjectSupport.bugReport, "bug_report.yml")] {
            XCTAssertEqual(url.path, ProjectSupport.repository.path + "/issues/new")
            XCTAssertEqual(try query(url)["template"], template)
        }
    }

    func testDonationLinksStayOnHTTPS() {
        XCTAssertFalse(ProjectSupport.donationLinks.isEmpty)
        for link in ProjectSupport.donationLinks {
            XCTAssertEqual(link.url.scheme, "https")
            XCTAssertFalse(link.title.isEmpty)
        }
    }

    func testTheWeChatCodeShipsLargeEnoughToScan() throws {
        let code = try XCTUnwrap(ProjectSupport.codes().first { $0.titleKey == "support.code.wechat" })
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(code.image as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        // Shown at 220 points, so it needs at least twice that on a Retina display.
        XCTAssertGreaterThanOrEqual(min(image.width, image.height), 440)
        XCTAssertEqual(image.width, image.height)
    }

    func testOnlyQRCodesThatShipAreOffered() throws {
        // A bundle remembers its folder's listing, so each case gets its own.
        func bundle(holding names: [String]) throws -> Bundle {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ProjectSupportTests." + UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
            for name in names { try Data([0]).write(to: folder.appendingPathComponent(name)) }
            return try XCTUnwrap(Bundle(url: folder))
        }
        XCTAssertEqual(ProjectSupport.codes(in: try bundle(holding: [])), [])

        let codes = ProjectSupport.codes(in: try bundle(holding: ["support-wechat.png"]))
        XCTAssertEqual(codes.map(\.titleKey), ["support.code.wechat"])
        XCTAssertEqual(codes.first?.hintKey, "support.code.wechat_hint")
        XCTAssertEqual(codes.first?.image.lastPathComponent, "support-wechat.png")
    }

    func testEveryLineOfThePageHasItsText() {
        for key in ["settings.pane.support", "support.thanks.title", "support.thanks.detail",
                    "support.star.title", "support.star.detail", "support.star.action", "support.star.feature", "support.star.bug",
                    "support.share.title", "support.share.detail", "support.share.action",
                    "support.share.copy", "support.share.copied", "support.share.subject", "support.share.message",
                    "support.coffee.title", "support.coffee.detail", "support.code.wechat", "support.code.wechat_hint"] {
            XCTAssertNotEqual(L10n.text(key), key)
        }
    }
}
