import XCTest
@testable import PacerCore

final class WhatsNewTests: XCTestCase {
    private func defaults() throws -> UserDefaults {
        let name = "WhatsNewTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private let catalog = [
        WhatsNew.Release(version: "3.0.10", items: [.init(symbol: "a", titleKey: "a", detailKey: "a")]),
        WhatsNew.Release(version: "3.0.9", items: [.init(symbol: "b", titleKey: "b", detailKey: "b")]),
        WhatsNew.Release(version: "3.0.2", items: [.init(symbol: "c", titleKey: "c", detailKey: "c")])
    ]

    private func versions(_ current: String, _ defaults: UserDefaults) -> [String] {
        WhatsNew.pending(current: current, defaults: defaults, releases: catalog).map(\.version)
    }

    func testEachUpdateShowsItsHighlightsOnceAndSkippedVersionsNewestFirst() throws {
        let defaults = try defaults()
        XCTAssertEqual(versions("3.0.2", defaults), ["3.0.2"], "A copy from before the note sees only the running version")
        XCTAssertEqual(versions("3.0.3", defaults), [], "A version without highlights updates quietly")
        WhatsNew.markSeen("3.0.2", defaults: defaults)
        XCTAssertEqual(versions("3.0.2", defaults), [], "Relaunching the same version stays quiet")
        XCTAssertEqual(versions("3.0.10", defaults), ["3.0.10", "3.0.9"], "Skipped updates are numeric, newest first")
        XCTAssertEqual(versions("3.0.9", defaults), ["3.0.9"], "Newer notes wait for their own version")
    }

    func testSettingsHistoryListsEveryNoteUpToTheRunningVersionNewestFirst() throws {
        let unordered = [catalog[2], catalog[0], catalog[1]]
        XCTAssertEqual(WhatsNew.history(upTo: "3.0.10", releases: unordered).map(\.version), ["3.0.10", "3.0.9", "3.0.2"])
        XCTAssertEqual(WhatsNew.history(upTo: "3.0.9", releases: unordered).map(\.version), ["3.0.9", "3.0.2"],
            "Notes for a newer version wait for it")
        XCTAssertEqual(WhatsNew.history(upTo: "3.0.1", releases: unordered).map(\.version), [])
        XCTAssertEqual(WhatsNew.history(upTo: nil, releases: unordered).map(\.version), ["3.0.10", "3.0.9", "3.0.2"])
        let defaults = try defaults()
        WhatsNew.markSeen("3.0.10", defaults: defaults)
        XCTAssertEqual(versions("3.0.10", defaults), [])
        XCTAssertEqual(WhatsNew.history(upTo: "3.0.10", releases: unordered).count, 3, "Seen notes stay readable")
        let latest = try XCTUnwrap(WhatsNew.releases.first?.version)
        XCTAssertEqual(WhatsNew.history(upTo: latest).map(\.version), WhatsNew.releases.map(\.version),
            "The shipped catalog stays newest first")
        XCTAssertEqual(WhatsNew.history(upTo: "3.2.1").first?.version, "3.2.1",
            "A targeted introduction is still part of the history")
    }

    func testOlderCopyNeverLowersTheRecordOrReplaysNotes() throws {
        let defaults = try defaults()
        WhatsNew.markSeen("3.0.10", defaults: defaults)
        WhatsNew.markSeen("3.0.9", defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: WhatsNew.defaultsKey), "3.0.10")
        XCTAssertEqual(versions("3.0.9", defaults), [])
        XCTAssertEqual(versions("3.0.10", defaults), [])
    }

    func test321IntroductionTargets320WithoutChangingCumulativeOlderHighlights() throws {
        let defaults = try defaults()
        func pending() -> [String] { WhatsNew.pending(current: "3.2.1", defaults: defaults).map(\.version) }
        XCTAssertEqual(pending(), [], "An unknown migration baseline must not opt into the targeted introduction")
        defaults.set("3.1.0", forKey: WhatsNew.defaultsKey)
        XCTAssertEqual(pending(), ["3.2.0", "3.1.2", "3.1.1"], "Older upgrades still collect their missed highlights")
        defaults.set("3.1.2", forKey: WhatsNew.defaultsKey)
        XCTAssertEqual(pending(), ["3.2.0"])
        defaults.set("3.2.0", forKey: WhatsNew.defaultsKey)
        XCTAssertEqual(pending(), ["3.2.1"])
        XCTAssertEqual(pending(), ["3.2.1"], "Opening without confirming keeps the introduction pending")
        WhatsNew.markSeen("3.2.1", defaults: defaults)
        XCTAssertEqual(pending(), [])
        XCTAssertEqual(WhatsNew.pending(current: "3.2.0", defaults: defaults), [])
    }

    func testShippedHighlightsAreOrderedAndLocalized() {
        let shipped = WhatsNew.releases.map(\.version)
        XCTAssertEqual(shipped, shipped.sorted { WhatsNew.newer($0, than: $1) }, "Newest first")
        XCTAssertEqual(Set(shipped).count, shipped.count)
        for release in WhatsNew.releases {
            XCTAssertFalse(release.items.isEmpty, release.version)
            for item in release.items {
                for key in [item.titleKey, item.detailKey] {
                    for language in [AppLanguage.english, .simplifiedChinese] {
                        XCTAssertNotEqual(L10n.text(key, language: language), key)
                    }
                }
            }
        }
    }
}
