import AppKit
import SwiftUI
import XCTest
@testable import PacerCore
@testable import PacerIsland

@MainActor
final class WidthMeasurementTests: XCTestCase {
    @MainActor private final class WidthCapture {
        var value: CGFloat = 0
    }

    func testThreeProviderTaskToolbarMeasuresItsWholeEnglishAndChineseWidth() async throws {
        _ = NSApplication.shared
        let domain = "TaskToolbarWidthTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        ProviderModules(codexMode: .enabled, claudeMode: .enabled, deepseekMode: .enabled).save(to: defaults)
        defaults.set("/synthetic/toolbar/codex", forKey: "codexHome")
        defaults.set("/synthetic/toolbar/claude", forKey: "claudeHome")
        defaults.set("/synthetic/toolbar/deepseek", forKey: "deepseekHome")
        defaults.set(false, forKey: "monitorSSH"); defaults.set(false, forKey: "monitorRemoteControl")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for demo in [false, true] {
            let model = IslandModel(demo: demo, demoClock: { now }, demoArguments: ["--demo-claude", "--demo-deepseek"], defaults: defaults,
                installation: .init(codexInstalled: true, claudeInstalled: true, deepseekInstalled: true))
            if !demo {
                model.now = now
                model.activities = DemoScenario.tasks(stage: .thinking, at: now)
                    + [DemoScenario.claudeTask(stage: .thinking, at: now), DemoScenario.deepseekTask(stage: .thinking, at: now)]
                model.desktopApplicationResolver = { _ in URL(fileURLWithPath: "/Synthetic.app") }
            }
            model.refreshDesktopApplications()
            try await Task.sleep(nanoseconds: 50_000_000)
            XCTAssertEqual(model.appButtonProviders, AgentProvider.allCases)
            XCTAssertEqual(model.visibleActivities.count, 4)
            for language in AppLanguage.allCases {
                let capture = WidthCapture()
                let header = TaskPagerView(model: model, language: language).header
                    .onPreferenceChange(ExpandedContentIdealWidth.self) { width in
                        DispatchQueue.main.async { capture.value = width }
                    }
                let host = NSHostingView(rootView: header)
                let oldAvailable = IslandWidth.expandedRange.lowerBound - 2 * IslandMetrics.edgeInset
                let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: oldAvailable, height: 28),
                    styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
                defer { window.orderOut(nil); window.close() }
                host.frame = NSRect(x: 0, y: 0, width: oldAvailable, height: 28)
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(nanoseconds: 50_000_000)
                let measured = capture.value
                if demo {
                    XCTAssertGreaterThan(measured, oldAvailable, "The paginated toolbar needs more than the old 404-point panel in \(language)")
                } else {
                    XCTAssertLessThanOrEqual(measured, oldAvailable, "Without the demo badge, the toolbar fits the existing minimum")
                }
                let title = L10n.text("layout.group.tasks", language: language)
                XCTAssertEqual(title, language == .english ? "Tasks" : "任务")
                let titleWidth = (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold)]).width
                let controlsWidth = NSHostingView(rootView: IslandPanelControls(model: model, language: language).fixedSize()).fittingSize.width
                XCTAssertGreaterThanOrEqual(measured, titleWidth + controlsWidth + 2 * IslandMetrics.rowInset + 80,
                    "The title, count, pagination and all three application buttons must contribute")
                model.updateMeasuredContentWidth(measured + 2 * IslandMetrics.edgeInset)
                let panel = IslandWidth.desired(expanded: true, notchWidth: 0, leading: 0, trailing: 0,
                    contentWidth: model.measuredContentWidth)
                if demo {
                    XCTAssertGreaterThan(panel, 404)
                } else {
                    XCTAssertEqual(panel, 404)
                }
                XCTAssertLessThanOrEqual(panel, 680)
                XCTAssertGreaterThanOrEqual(panel - 2 * IslandMetrics.edgeInset, measured)
                host.frame.size.width = panel - 2 * IslandMetrics.edgeInset
                host.layoutSubtreeIfNeeded()
                XCTAssertLessThanOrEqual(host.fittingSize.width, host.frame.width + 1)
            }
            await model.shutdown()
        }
    }

    func testMeasurementsRelayoutOnlyWhenRoundedContentChanges() async {
        let model = IslandModel(demo: true)
        var layouts = 0
        model.onLayoutChange = { layouts += 1 }
        model.updateMeasuredCompactWidth(110.1)
        XCTAssertEqual(layouts, 1)
        model.updateMeasuredCompactWidth(110.4)
        XCTAssertEqual(layouts, 1, "Repeated subpoint measurements must not restart the animation")
        model.updateMeasuredCompactWidth(.nan)
        model.updateMeasuredCompactWidth(-1)
        XCTAssertEqual(layouts, 1)
        model.updateMeasuredCompactWidth(40)
        XCTAssertEqual(layouts, 2, "The header can shrink after activity ends")
        model.updateMeasuredContentWidth(650.2)
        model.updateMeasuredContentWidth(650.4)
        XCTAssertEqual(layouts, 3)
        model.updateMeasuredContentWidth(0)
        XCTAssertEqual(layouts, 4, "Removing all task rows clears their preferred width")
        XCTAssertEqual(model.measuredContentWidth, 0)
        await model.shutdown()
    }

    func testApplyingSettingsKeepsTheMeasuredBarWidth() async {
        let name = "WidthMeasurementTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let model = IslandModel(demo: true, defaults: defaults)
        model.updateMeasuredCompactWidth(212)
        defaults.set(false, forKey: "showAppButtons")
        model.applySettings(sourceChanged: false)
        XCTAssertEqual(model.measuredCompactWidth, 212,
            "A setting that leaves the bar unchanged brings no new measurement, so the last one must stay")
        await model.shutdown()
    }
}
