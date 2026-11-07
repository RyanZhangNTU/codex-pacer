import XCTest
@testable import PacerCore
@testable import PacerIsland
import PacerTestSupport

@MainActor
final class CompactPresentationCacheTests: XCTestCase {
    private func defaults() throws -> (UserDefaults, String) {
        let suite = testDefaultsName("CompactPresentationCacheTests")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(false, forKey: "monitorSSH")
        return (defaults, suite)
    }

    func testAlternatingStatusRequestsKeepSeparateCachedLayoutsAndInvalidateIndependently() async throws {
        let (defaults, suite) = try defaults()
        defer { removeTestDefaults(suite) }
        CompactIslandLayout(leading: [.activity, .status, .tps], trailing: [.quota]).save(to: defaults)
        let model = IslandModel(defaults: defaults,
            installation: .init(codexInstalled: true, claudeInstalled: false, deepseekInstalled: false))
        model.now = Date(timeIntervalSince1970: 1_800_000_000)
        for showsStatus in [true, false, true, false] {
            let output = model.compactPresentation(showsStatus: showsStatus)
            XCTAssertEqual(output.leading.contains("status"), showsStatus)
            XCTAssertEqual(output.component(.status).shown, showsStatus)
        }
        XCTAssertEqual(Set(model.compactPresentationCache.keys), [true, false])
        let shown = try XCTUnwrap(model.compactPresentationCache[true])
        let hidden = try XCTUnwrap(model.compactPresentationCache[false])
        XCTAssertTrue(shown.layout.components.contains(.status))
        XCTAssertFalse(hidden.layout.components.contains(.status))
        XCTAssertEqual(model.compactPresentation(showsStatus: true), shown.output)
        XCTAssertEqual(model.compactPresentationCache[false]?.output, hidden.output)
        defaults.set("pace", forKey: "compactMetric")
        _ = model.compactPresentation(showsStatus: false)
        XCTAssertEqual(model.compactPresentationCache[false]?.request.options.metric, .pace)
        XCTAssertEqual(model.compactPresentationCache[true]?.request.options.metric, .remaining)
        _ = model.compactPresentation(showsStatus: true)
        XCTAssertEqual(model.compactPresentationCache[true]?.request.options.metric, .pace)
        await model.shutdown()
    }

    func testStatusRequestsHaveSeparateCacheSlotsEvenWhenTheSavedLayoutOmitsStatus() async throws {
        let (defaults, suite) = try defaults()
        defer { removeTestDefaults(suite) }
        CompactIslandLayout.standard.save(to: defaults)
        let model = IslandModel(defaults: defaults,
            installation: .init(codexInstalled: false, claudeInstalled: false, deepseekInstalled: false))
        model.now = Date(timeIntervalSince1970: 1_800_000_000)
        let first = model.compactPresentation(showsStatus: true)
        XCTAssertEqual(model.compactPresentation(showsStatus: false), first)
        XCTAssertEqual(Set(model.compactPresentationCache.keys), [true, false])
        await model.shutdown()
    }

    func testInvalidProjectionAndMissingComponentsHideSafelyThenRecover() async throws {
        let (defaults, suite) = try defaults()
        defer { removeTestDefaults(suite) }
        let model = IslandModel(defaults: defaults,
            installation: .init(codexInstalled: false, claudeInstalled: false, deepseekInstalled: false))
        model.now = Date(timeIntervalSince1970: .infinity)
        XCTAssertEqual(model.compactPresentation(), .empty)
        XCTAssertTrue(model.compactPresentationCache.isEmpty)
        for component in CompactIslandLayout.Component.allCases {
            XCTAssertFalse(model.compactComponent(component).visible)
        }
        model.now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertNotEqual(model.compactPresentation(), .empty)
        XCTAssertTrue(model.compactComponent(.activity).visible)
        let cached = try XCTUnwrap(model.compactPresentationCache[true])
        model.compactPresentationCache[true] = (cached.layout, cached.request, .empty)
        XCTAssertFalse(model.compactComponent(.activity).visible)
        model.compactPresentationCache.removeAll()
        XCTAssertTrue(model.compactComponent(.activity).visible)
        await model.shutdown()
    }

    func testMalformedSavedOptionsKeepTheirOriginalDefaultsWithoutRewritingPreferences() async throws {
        let (defaults, suite) = try defaults()
        defer { removeTestDefaults(suite) }
        defaults.set("future", forKey: "compactSingleTask")
        defaults.set("future", forKey: "compactMetric")
        defaults.set("", forKey: QuotaRingSlot.outer.defaultsKey)
        defaults.set("future", forKey: QuotaRingSlot.inner.defaultsKey)
        let model = IslandModel(defaults: defaults,
            installation: .init(codexInstalled: true, claudeInstalled: false, deepseekInstalled: false))
        _ = model.compactPresentation()
        let options = try XCTUnwrap(model.compactPresentationCache[true]?.request.options)
        XCTAssertEqual(options.singleTask, .stage); XCTAssertEqual(options.metric, .remaining)
        XCTAssertEqual(options.rings, [.none, .none])
        XCTAssertEqual(defaults.string(forKey: "compactSingleTask"), "future")
        XCTAssertEqual(defaults.string(forKey: "compactMetric"), "future")
        XCTAssertEqual(defaults.string(forKey: QuotaRingSlot.outer.defaultsKey), "")
        XCTAssertEqual(defaults.string(forKey: QuotaRingSlot.inner.defaultsKey), "future")
        await model.shutdown()
    }
}
