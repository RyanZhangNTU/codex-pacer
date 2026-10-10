import XCTest
@testable import PacerCore

final class CompactIslandLayoutTests: XCTestCase {
    func testMovesPreserveOneComponentAndSupportPositionsAndInsertion() {
        var layout = CompactIslandLayout.standard
        layout.move(.tps, to: .trailing)
        layout.move(.status, to: .trailing, before: .tps)
        XCTAssertEqual(layout.trailing.suffix(2), [.status, .tps])
        XCTAssertEqual(layout.leading, [.activity])
        layout.move(.tps, to: .trailing, before: .quotaGauge)
        XCTAssertEqual(layout.leading, [.activity])
        XCTAssertEqual(layout.trailing, [.lowQuotaWarning, .tps, .quotaGauge, .quota, .quotaDelayWarning, .sshWarning, .status])
        let previous = layout
        layout.move(.status, to: .trailing, before: .status)
        XCTAssertEqual(layout, previous, "Dropping on itself must not lose the dragged component")
        layout.shift(.tps, by: -1)
        XCTAssertEqual(layout.trailing.first, .tps)
        layout.shift(.tps, by: -1)
        XCTAssertEqual(layout.trailing.first, .tps, "Keyboard reordering stops at the boundary")
        layout.shift(.tps, by: 100)
        XCTAssertEqual(layout.trailing.last, .tps)
        layout.hide(.status)
        XCTAssertFalse(layout.components.contains(.status))
        XCTAssertTrue(layout.components.contains(.tps))
    }
    func testDefaultsAndCustomLayoutPersistWithoutChangingOtherPreferences() throws {
        let name = "CompactLayoutTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("fixed", forKey: "islandWidthMode")
        defaults.set(610, forKey: "specifiedIslandWidth")
        XCTAssertEqual(CompactIslandLayout.load(from: defaults), .standard)
        XCTAssertNil(defaults.data(forKey: CompactIslandLayout.defaultsKey), "A new or upgraded profile must not write settings on load")
        var layout = CompactIslandLayout(leading: [.tps], trailing: [.quota, .firstOutput])
        layout.save(to: defaults)
        XCTAssertEqual(CompactIslandLayout.load(from: defaults), layout)
        XCTAssertEqual(IslandWidthSettings.load(from: defaults), .init(mode: .fixed, width: 610))
        for component in layout.components { layout.hide(component) }
        layout.save(to: defaults)
        XCTAssertTrue(CompactIslandLayout.load(from: defaults).components.isEmpty, "Hiding everything is intentional")
        for invalid in [Data("broken".utf8), Data(#"{"version":7,"leading":[],"trailing":[]}"#.utf8), Data(repeating: 0, count: 8193)] {
            defaults.set(invalid, forKey: CompactIslandLayout.defaultsKey)
            XCTAssertEqual(CompactIslandLayout.load(from: defaults), .standard)
        }
    }
    func testLegacyCenterMigrationPreservesChoicesWithoutWritingUntilSave() throws {
        let data = Data(#"{"version":1,"leading":["tps","futureMetric","status"],"center":["tps","firstOutput","settings"],"trailing":["status"]}"#.utf8)
        let layout = try JSONDecoder().decode(CompactIslandLayout.self, from: data).normalized
        XCTAssertEqual(layout.leading, [.tps, .status, .firstOutput])
        XCTAssertTrue(layout.trailing.isEmpty)
        let name = "CompactLayoutMigrationTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(data, forKey: CompactIslandLayout.defaultsKey)
        XCTAssertEqual(CompactIslandLayout.load(from: defaults), layout)
        XCTAssertEqual(defaults.data(forKey: CompactIslandLayout.defaultsKey), data)
        layout.save(to: defaults)
        let saved = try XCTUnwrap(defaults.data(forKey: CompactIslandLayout.defaultsKey))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, 6)
        XCTAssertNil(object["center"])
        XCTAssertEqual(CompactIslandLayout.load(from: defaults), layout)
    }
    func testCameraClearanceAndAdaptiveShrinkingRespectExpandedAndFixedWidths() {
        let widths = IslandWidthSettings()
        let full = widths.desiredWidth(expanded: false, notchWidth: 0, leading: 300, trailing: 80, headerWidth: 420)
        let compact = widths.desiredWidth(expanded: false, notchWidth: 0, leading: 300, trailing: 80, headerWidth: 112)
        XCTAssertEqual(compact, 114)
        XCTAssertLessThan(compact, full, "Hidden content must not retain a previously measured wide header")
        XCTAssertEqual(widths.desiredWidth(expanded: false, notchWidth: 180, leading: 0, trailing: 0, headerWidth: 218), 240)
        XCTAssertGreaterThanOrEqual(widths.desiredWidth(expanded: true, notchWidth: 0, leading: 0, trailing: 0, headerWidth: 112), 440)
        XCTAssertEqual(IslandWidthSettings(mode: .fixed, width: 600).desiredWidth(expanded: false,
            notchWidth: 0, leading: 0, trailing: 0, headerWidth: 112), 600)
    }
    func testLegacyComponentMigrationDropsRemovedControlsAndPreservesCustomOrder() throws {
        let data = Data(#"{"version":2,"leading":["statusIcon","subagentCount","taskCount","settings"],"trailing":["pace","quotaMetric","quotaWindow","quotaLabel","resetCountdown","quotaWarning","freshness","pin","refresh","quit","collapse"]}"#.utf8)
        let layout = try JSONDecoder().decode(CompactIslandLayout.self, from: data).normalized
        XCTAssertEqual(layout.leading, [.activity], "The merged badge replaces both former task components once")
        XCTAssertEqual(layout.trailing, [.quotaGauge, .quota, .quotaLabel, .timeRemaining, .lowQuotaWarning, .quotaDelayWarning])
        let standard = Data(#"{"version":2,"leading":["statusIcon","status","tps"],"trailing":["quotaWarning","quotaMetric","quotaWindow","freshness"]}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(CompactIslandLayout.self, from: standard), .standard)
        let empty = Data(#"{"version":2,"leading":[],"trailing":[]}"#.utf8)
        XCTAssertTrue(try JSONDecoder().decode(CompactIslandLayout.self, from: empty).components.isEmpty)
    }
    func testActivityBadgeMergesStatusIconAndTaskCountAndOnlyTheFormerDefaultDropsStatusText() throws {
        func decode(_ leading: [String], trailing: [String] = ["codexQuota"], version: Int = 4) throws -> CompactIslandLayout {
            let object: [String: Any] = ["version": version, "leading": leading, "trailing": trailing]
            return try JSONDecoder().decode(CompactIslandLayout.self, from: JSONSerialization.data(withJSONObject: object)).normalized
        }
        XCTAssertEqual(try decode(["statusIcon", "status", "taskCount", "tps"]).leading, [.activity, .tps],
            "The untouched former default lane adopts the new default even when the other lane was customized")
        XCTAssertEqual(try decode(["statusIcon", "status", "taskCount", "tps"],
            trailing: ["lowQuotaWarning", "codexQuota", "claudeQuota", "quotaLabel", "quotaDelayWarning", "sshWarning"]), .standard)
        XCTAssertEqual(try decode(["tps", "statusIcon", "status"]).leading, [.tps, .activity, .status], "Chosen status text stays")
        XCTAssertEqual(try decode(["taskCount", "firstOutput", "statusIcon"]).leading, [.activity, .firstOutput],
            "The first former task component keeps its position")
        XCTAssertEqual(try decode(["status"], trailing: ["taskCount"]), CompactIslandLayout(leading: [.status], trailing: [.activity]))
        XCTAssertEqual(try decode(["statusIcon", "status", "taskCount", "tps"], version: 5).leading, [.activity, .status, .tps],
            "A current schema is never treated as the former default")
        XCTAssertTrue(try decode([], trailing: []).components.isEmpty, "An intentionally empty bar stays empty")
        XCTAssertEqual(CompactIslandLayout.Group.tasks.components, [.activity, .status])
    }
    func testCombinedQuotaMigratesInPlaceAndHiddenQuotaStaysHiddenAcrossAllLegacySchemas() throws {
        for version in 1...3 {
            let object: [String: Any] = ["version": version, "leading": ["tps", "quotaMetric", "status"],
                "center": ["quotaMetric", "futureMetric"], "trailing": ["timeRemaining", "quotaMetric", "sshWarning"]]
            let layout = try JSONDecoder().decode(CompactIslandLayout.self, from: JSONSerialization.data(withJSONObject: object)).normalized
            XCTAssertEqual(layout.leading, [.tps, .quotaGauge, .quota, .status])
            XCTAssertEqual(layout.trailing, [.timeRemaining, .sshWarning], "Duplicated legacy quota must not create extra values")
            let hidden = try JSONSerialization.data(withJSONObject: ["version": version, "leading": ["tps"], "trailing": ["sshWarning"]])
            XCTAssertEqual(try JSONDecoder().decode(CompactIslandLayout.self, from: hidden),
                CompactIslandLayout(leading: [.tps], trailing: [.sshWarning]))
        }
    }
    func testProviderQuotaValuesMergeIntoRingsAndOneAlternatingValue() throws {
        func decode(_ leading: [String], _ trailing: [String], version: Int) throws -> CompactIslandLayout {
            let object: [String: Any] = ["version": version, "leading": leading, "trailing": trailing]
            return try JSONDecoder().decode(CompactIslandLayout.self, from: JSONSerialization.data(withJSONObject: object))
        }
        XCTAssertEqual(try decode(["taskCount", "tps"], ["statusIcon", "codexQuota", "claudeQuota", "lowQuotaWarning", "quotaDelayWarning", "sshWarning"], version: 4),
            CompactIslandLayout(leading: [.activity, .tps], trailing: [.quotaGauge, .quota, .lowQuotaWarning, .quotaDelayWarning, .sshWarning]),
            "Both provider values stay visible as rings plus the alternating value at the first one's position")
        XCTAssertEqual(try decode(["activity", "tps"], ["lowQuotaWarning", "codexQuota", "claudeQuota", "quotaLabel", "quotaDelayWarning", "sshWarning"], version: 5),
            .standard, "The untouched former default adopts the new default without the label")
        XCTAssertEqual(try decode(["activity"], ["claudeQuota", "sshWarning"], version: 5).trailing, [.quota, .sshWarning],
            "A single provider value becomes the value alone")
        XCTAssertEqual(try decode(["codexQuota", "tps"], ["claudeQuota"], version: 5),
            CompactIslandLayout(leading: [.quotaGauge, .quota, .tps]), "Values split across lanes merge at the first position")
        XCTAssertTrue(try decode(["codexQuota"], [], version: 6).components.isEmpty, "Current layouts never reinterpret provider names")
        XCTAssertEqual(CompactIslandLayout.Group.quota.components, [.quota, .quotaGauge, .quotaLabel, .timeRemaining])
        XCTAssertTrue(CompactIslandLayout.standard.components.isSuperset(of: [.quotaGauge, .quota, .lowQuotaWarning]),
            "Rings, the alternating value and the 5h warning are on by default")
    }
    func testQuotaComponentsFollowEnabledModulesAndChoicesSurviveSaveAndReload() throws {
        let name = "CompactProviderLayoutTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let legacy = Data(#"{"version":3,"leading":["quotaMetric","tps"],"trailing":["taskCount"]}"#.utf8)
        defaults.set(legacy, forKey: CompactIslandLayout.defaultsKey)
        var layout = CompactIslandLayout.load(from: defaults)
        XCTAssertEqual(defaults.data(forKey: CompactIslandLayout.defaultsKey), legacy, "Previewing migration must not save it")
        let migrated = layout
        let configurations: [Set<AgentProvider>] = [[], [.codex], [.claude], [.codex, .claude]]
        for providers in configurations {
            XCTAssertEqual(layout.visibleComponents(in: .leading, providers: providers), providers.isEmpty ? [.tps] : [.quotaGauge, .quota, .tps])
            layout.save(to: defaults)
            layout = CompactIslandLayout.load(from: try XCTUnwrap(UserDefaults(suiteName: name)))
            XCTAssertEqual(layout, migrated, "Disabling every module must not remove saved quota positions")
        }
        layout.move(.quota, to: .trailing, before: .activity)
        layout.hide(.quotaGauge)
        layout.save(to: defaults)
        let saved = CompactIslandLayout.load(from: defaults)
        XCTAssertEqual(saved.leading, [.tps])
        XCTAssertEqual(saved.trailing, [.quota, .activity])
        XCTAssertFalse(saved.components.contains(.quotaGauge), "Explicitly hidden rings stay hidden")
    }
    func testKeyboardReorderingSkipsInactiveQuotaAndKeepsHiddenComponents() {
        var layout = CompactIslandLayout(leading: [.quotaGauge, .tps, .firstOutput])
        layout.shift(.firstOutput, by: -1, providers: [])
        XCTAssertEqual(layout.visibleComponents(in: .leading, providers: []), [.firstOutput, .tps])
        XCTAssertEqual(layout.leading, [.quotaGauge, .firstOutput, .tps])
        layout.shift(.tps, by: -100, providers: [])
        XCTAssertEqual(layout.leading, [.quotaGauge, .tps, .firstOutput], "Inactive rings keep their position")
        let previous = layout
        layout.shift(.quotaGauge, by: 1, providers: [])
        XCTAssertEqual(layout, previous, "An inactive component cannot be moved by keyboard")
    }
}
