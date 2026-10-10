import XCTest
@testable import PacerCore

final class CompactIslandLayoutTests: XCTestCase {
    func testMovesPreserveOneComponentAndSupportPositionsAndInsertion() {
        var layout = CompactIslandLayout.standard
        layout.move(.tps, to: .trailing)
        layout.move(.status, to: .trailing, before: .tps)
        XCTAssertEqual(layout.trailing.suffix(2), [.status, .tps])
        XCTAssertEqual(layout.leading, [.statusIcon, .taskCount])
        layout.move(.tps, to: .trailing, before: .codexQuota)
        XCTAssertEqual(layout.leading, [.statusIcon, .taskCount])
        XCTAssertEqual(layout.trailing, [.lowQuotaWarning, .tps, .codexQuota, .claudeQuota, .quotaLabel, .quotaDelayWarning, .sshWarning, .status])
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
        var layout = CompactIslandLayout(leading: [.tps], trailing: [.codexQuota, .firstOutput])
        layout.save(to: defaults)
        XCTAssertEqual(CompactIslandLayout.load(from: defaults), layout)
        XCTAssertEqual(IslandWidthSettings.load(from: defaults), .init(mode: .fixed, width: 610))
        for component in layout.components { layout.hide(component) }
        layout.save(to: defaults)
        XCTAssertTrue(CompactIslandLayout.load(from: defaults).components.isEmpty, "Hiding everything is intentional")
        for invalid in [Data("broken".utf8), Data(#"{"version":5,"leading":[],"trailing":[]}"#.utf8), Data(repeating: 0, count: 8193)] {
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
        XCTAssertEqual(object["version"] as? Int, 4)
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
        XCTAssertEqual(layout.leading, [.statusIcon, .taskCount])
        XCTAssertEqual(layout.trailing, [.codexQuota, .claudeQuota, .quotaLabel, .timeRemaining, .lowQuotaWarning, .quotaDelayWarning])
        let standard = Data(#"{"version":2,"leading":["statusIcon","status","tps"],"trailing":["quotaWarning","quotaMetric","quotaWindow","freshness"]}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(CompactIslandLayout.self, from: standard), .standard)
        let empty = Data(#"{"version":2,"leading":[],"trailing":[]}"#.utf8)
        XCTAssertTrue(try JSONDecoder().decode(CompactIslandLayout.self, from: empty).components.isEmpty)
    }
    func testCombinedQuotaMigratesInPlaceAndHiddenQuotaStaysHiddenAcrossAllLegacySchemas() throws {
        for version in 1...3 {
            let object: [String: Any] = ["version": version, "leading": ["tps", "quotaMetric", "status"],
                "center": ["quotaMetric", "futureMetric"], "trailing": ["timeRemaining", "quotaMetric", "sshWarning"]]
            let layout = try JSONDecoder().decode(CompactIslandLayout.self, from: JSONSerialization.data(withJSONObject: object)).normalized
            XCTAssertEqual(layout.leading, [.tps, .codexQuota, .claudeQuota, .status])
            XCTAssertEqual(layout.trailing, [.timeRemaining, .sshWarning], "Duplicated legacy quota must not create extra values")
            let hidden = try JSONSerialization.data(withJSONObject: ["version": version, "leading": ["tps"], "trailing": ["sshWarning"]])
            XCTAssertEqual(try JSONDecoder().decode(CompactIslandLayout.self, from: hidden),
                CompactIslandLayout(leading: [.tps], trailing: [.sshWarning]))
        }
    }
    func testProviderFilteringAndIndependentQuotaChoicesSurviveSaveAndReload() throws {
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
            let quota: [CompactIslandLayout.Component] = [.codexQuota, .claudeQuota].filter { $0.isAvailable(for: providers) }
            XCTAssertEqual(layout.visibleComponents(in: .leading, providers: providers), quota + [.tps])
            layout.save(to: defaults)
            layout = CompactIslandLayout.load(from: try XCTUnwrap(UserDefaults(suiteName: name)))
            XCTAssertEqual(layout, migrated, "Disabling a provider must not remove its saved quota position")
        }
        layout.move(.claudeQuota, to: .trailing, before: .taskCount)
        layout.hide(.codexQuota)
        layout.save(to: defaults)
        let saved = CompactIslandLayout.load(from: defaults)
        XCTAssertEqual(saved.leading, [.tps])
        XCTAssertEqual(saved.trailing, [.claudeQuota, .taskCount])
        XCTAssertFalse(saved.components.contains(.codexQuota), "An explicitly hidden provider stays hidden on re-enable")
    }
    func testKeyboardReorderingSkipsInactiveQuotaAndKeepsHiddenComponents() {
        var layout = CompactIslandLayout(leading: [.codexQuota, .claudeQuota, .tps])
        layout.shift(.codexQuota, by: 1, providers: [.codex])
        XCTAssertEqual(layout.visibleComponents(in: .leading, providers: [.codex]), [.tps, .codexQuota])
        XCTAssertEqual(layout.leading, [.claudeQuota, .tps, .codexQuota])
        layout.shift(.tps, by: 100, providers: [.codex])
        XCTAssertEqual(layout.leading, [.claudeQuota, .codexQuota, .tps])
        let previous = layout
        layout.shift(.codexQuota, by: -100, providers: [.codex])
        layout.shift(.claudeQuota, by: 1, providers: [.codex])
        XCTAssertEqual(layout, previous)
    }
}
