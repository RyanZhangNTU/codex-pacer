import Foundation
import XCTest
@testable import PacerEngineSupport
@testable import PacerCore

final class EngineGuidePagesTests: XCTestCase {
    private func plan(_ current: String = "4.2.0", seen: String? = nil, welcomed: Int = 4, demo: Bool = false,
                      settings: Bool = false, welcome: Bool = false, note: Bool = false, language: String = "en") throws -> EngineGuidePages.Value {
        try XCTUnwrap(EngineGuidePages.project(.init(current: current, seen: seen, welcomed: welcomed, language: language,
            demo: demo, settings: settings, forceWelcome: welcome, forceWhatsNew: note)))
    }
    func testFreshInstallAndMajorUpgradePreferWelcomeAndRecordOnlyTheNoteAtLaunch() throws {
        for old in [0, 3] {
            let value = try plan(seen: "3.3.0", welcomed: old)
            XCTAssertEqual(value.page, "welcome"); XCTAssertEqual(value.major, WelcomeGuide.currentMajor)
            XCTAssertEqual(value.nextSeen, "4.2.0"); XCTAssertTrue(value.recordLaunch); XCTAssertTrue(value.recordClose)
        }
        XCTAssertNil(try plan(seen: "4.2.0").page)
        XCTAssertNil(try plan(seen: "5.0.0", welcomed: 5).page)
    }
    func testDemoAndSettingsAreQuietAndOnlyDemoSuppressesForcedPageRecords() throws {
        for pair in [(true, false), (false, true), (true, true)] {
            let quiet = try plan(welcomed: 0, demo: pair.0, settings: pair.1)
            XCTAssertNil(quiet.page); XCTAssertFalse(quiet.recordLaunch); XCTAssertEqual(quiet.recordClose, !pair.0)
            let guide = try plan(welcomed: 0, demo: pair.0, settings: pair.1, welcome: true)
            XCTAssertEqual(guide.page, "welcome"); XCTAssertEqual(guide.recordLaunch, !pair.0); XCTAssertEqual(guide.recordClose, !pair.0)
            let note = try plan(demo: pair.0, settings: pair.1, note: true)
            XCTAssertEqual(note.page, "whatsNew"); XCTAssertFalse(note.recordLaunch); XCTAssertEqual(note.recordClose, !pair.0)
        }
    }
    func testCumulativeNotesTargetedBaselineAndSilentVersionsReuseMacSelection() throws {
        for seen in [nil, "3.1.0", "3.2.0", "3.2.1", "4.1.0"] as [String?] {
            let value = try plan(seen: seen)
            XCTAssertEqual(value.releases.map(\.version), WhatsNew.pending(current: "4.2.0", seen: seen).map(\.version))
            XCTAssertEqual(value.page, "whatsNew"); XCTAssertFalse(value.recordLaunch); XCTAssertTrue(value.recordClose)
        }
        XCTAssertEqual(try plan("3.2.1", seen: "3.2.0").releases.map(\.version), ["3.2.1"])
        XCTAssertTrue(try plan("3.2.1", seen: "3.1.2").releases.allSatisfy { $0.version != "3.2.1" })
        let silent = try plan("4.2.1", seen: "4.2.0")
        XCTAssertNil(silent.page); XCTAssertTrue(silent.recordLaunch); XCTAssertEqual(silent.nextSeen, "4.2.1")
    }
    func testRecordedVersionNeverMovesBackwardsAndForcedNotesHaveContent() throws {
        for seen in ["4.2.0", "4.10.0", "5.0.0"] {
            let value = try plan(seen: seen)
            XCTAssertEqual(value.nextSeen, seen); XCTAssertNil(value.page)
            let forced = try plan(seen: seen, note: true)
            XCTAssertEqual(forced.page, "whatsNew"); XCTAssertEqual(forced.nextSeen, seen); XCTAssertFalse(forced.releases.isEmpty)
        }
    }
    func test424UpgradeShowsTheSharedMoveNoteOnceAndFreshInstallKeepsWelcome() throws {
        for language in AppLanguage.allCases {
            let upgrade = try plan("4.2.4", seen: "4.2.3", language: language.rawValue)
            XCTAssertEqual(upgrade.page, "whatsNew")
            let item = try XCTUnwrap(upgrade.releases.first?.items.first)
            XCTAssertEqual(upgrade.releases.map(\.version), ["4.2.4"])
            XCTAssertEqual(item.title, L10n.text("whats_new.free_move", language: language))
            XCTAssertNotEqual(item.title, "whats_new.free_move")
            XCTAssertEqual(try plan("4.2.4", seen: "4.2.3", welcomed: 0).page, "welcome")
            XCTAssertNil(try plan("4.2.4", seen: "4.2.4").page)
            XCTAssertEqual(WhatsNew.history(upTo: "4.2.4").first?.version, "4.2.4", "Mac and Windows share one release list")
        }
    }
    func testHistoryContainsEveryReleaseAndUsesBothAuthoritativeCatalogs() throws {
        for language in AppLanguage.allCases {
            let value = try plan(language: language.rawValue)
            let expected = WhatsNew.history(upTo: "4.2.0")
            XCTAssertEqual(value.history.map(\.version), expected.map(\.version)); XCTAssertEqual(value.steps.count, 2)
            for (actual, release) in zip(value.history, expected) {
                XCTAssertEqual(actual.items.count, release.items.count)
                for (item, source) in zip(actual.items, release.items) {
                    XCTAssertEqual(item.title, L10n.text(source.titleKey, language: language))
                    XCTAssertEqual(item.detail, L10n.text(source.detailKey, language: language))
                    XCTAssertFalse(item.title.isEmpty); XCTAssertFalse(item.detail.isEmpty)
                }
            }
            XCTAssertEqual(value.moduleOff.count, 3)
        }
    }
    func testPublicLinksAndPackagedQRCodeUseProjectSupport() throws {
        let english = try plan(), chinese = try plan(language: "zh-Hans")
        XCTAssertEqual(english.links["star"], ProjectSupport.star.absoluteString)
        XCTAssertEqual(english.links["feature"], ProjectSupport.featureRequest.absoluteString)
        XCTAssertEqual(english.links["bug"], ProjectSupport.bugReport.absoluteString)
        XCTAssertEqual(english.links["donate"], ProjectSupport.donationLinks.first?.url.absoluteString)
        XCTAssertTrue(chinese.links["manual"]!.hasSuffix("guide.zh-CN.md"))
        XCTAssertEqual(english.supportCode, "support-wechat.png")
        XCTAssertEqual(english.qqGroup, ProjectSupport.qqGroupNumber)
        XCTAssertEqual(english.qqCode, "support-qq-group.png")
        XCTAssertFalse(String(data: try JSONEncoder().encode(english), encoding: .utf8)!.contains(NSHomeDirectory()))
    }
    func testReadOnlyWireAndMalformedRequests() throws {
        let input: [String: Any] = ["current": "4.2.0", "welcomed": 0, "language": "en", "demo": true, "settings": false, "forceWelcome": true, "forceWhatsNew": false]
        func command(_ request: [String: Any]) throws -> EngineCommand {
            try EngineCommand.decode(JSONSerialization.data(withJSONObject: ["protocolVersion": 1, "id": "guide-qa", "method": "guidePages", "params": ["shell": ["guide": request]]]))
        }
        XCTAssertTrue(EngineShellProjection.methods.contains("guidePages"))
        let reply = try XCTUnwrap(EngineShellProjection.reply(command(input)))
        XCTAssertTrue(String(data: reply, encoding: .utf8)!.contains("guide-qa"))
        for (key, bad) in [("current", "../private" as Any), ("language", "unknown" as Any), ("welcomed", -1 as Any), ("seen", String(repeating: "x", count: 65) as Any)] {
            var request = input; request[key] = bad; XCTAssertNil(try EngineShellProjection.reply(command(request)))
        }
    }
}
