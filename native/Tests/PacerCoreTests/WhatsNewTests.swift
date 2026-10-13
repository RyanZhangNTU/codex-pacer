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

    func testOlderCopyNeverLowersTheRecordOrReplaysNotes() throws {
        let defaults = try defaults()
        WhatsNew.markSeen("3.0.10", defaults: defaults)
        WhatsNew.markSeen("3.0.9", defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: WhatsNew.defaultsKey), "3.0.10")
        XCTAssertEqual(versions("3.0.9", defaults), [])
        XCTAssertEqual(versions("3.0.10", defaults), [])
    }

    func testShippedHighlightsAreOrderedAndLocalized() {
        let shipped = WhatsNew.releases.map(\.version)
        XCTAssertEqual(shipped, shipped.sorted { WhatsNew.newer($0, than: $1) }, "Newest first")
        XCTAssertEqual(Set(shipped).count, shipped.count)
        for release in WhatsNew.releases {
            XCTAssertFalse(release.items.isEmpty, release.version)
            for item in release.items {
                for key in [item.titleKey, item.detailKey] {
                    XCTAssertNotEqual(L10n.text(key, language: .english), key)
                }
            }
        }
    }
}
