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

        // The QQ group's code is not a coffee code, and it too needs its image.
        XCTAssertNil(ProjectSupport.qqGroupCode(in: try bundle(holding: ["support-wechat.png"])))
        let both = try bundle(holding: ["support-wechat.png", "support-qq-group.png"])
        XCTAssertEqual(ProjectSupport.codes(in: both).map(\.titleKey), ["support.code.wechat"])
        let qq = try XCTUnwrap(ProjectSupport.qqGroupCode(in: both))
        XCTAssertEqual(qq.titleKey, "support.qq.code")
        XCTAssertEqual(qq.hintKey, "support.qq.hint")
        XCTAssertEqual(qq.image.lastPathComponent, "support-qq-group.png")
    }

    func testTheQQGroupShipsWithItsNumberAndCode() {
        XCTAssertEqual(ProjectSupport.qqGroupNumber, "1131553244")
        XCTAssertNotNil(ProjectSupport.qqGroupCode(), "The app bundles the group's QR code")
        XCTAssertTrue(L10n.text("support.qq.number", ProjectSupport.qqGroupNumber).contains(ProjectSupport.qqGroupNumber))
    }

    func testEveryLineOfThePageHasItsText() {
        for key in ["settings.pane.support", "support.thanks.title", "support.thanks.detail",
                    "support.star.title", "support.star.detail", "support.star.action", "support.star.feature", "support.star.bug",
                    "support.share.title", "support.share.detail", "support.share.action",
                    "support.share.copy", "support.share.copied", "support.share.subject", "support.share.message",
                    "support.coffee.title", "support.coffee.detail", "support.code.wechat", "support.code.wechat_hint",
                    "main.support.feedback", "support.qq.title", "support.qq.number", "support.qq.copy",
                    "support.qq.code", "support.qq.hint"] {
            XCTAssertNotEqual(L10n.text(key), key)
        }
    }
}
