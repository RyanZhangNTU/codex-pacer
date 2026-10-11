import AppKit
import SwiftUI
import XCTest
@testable import PacerCore
@testable import PacerIsland

@MainActor
final class CompactLayoutEditorTests: XCTestCase {
    private func fixture() throws -> (IslandModel, UserDefaults, String, URL) {
        let name = "com.codexpacer.compact-editor-tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaults.set(directory.path, forKey: "codexHome")
        defaults.set(directory.path, forKey: "claudeHome")
        ProviderModules(codexMode: .enabled, claudeMode: .enabled).save(to: defaults)
        let model = IslandModel(demo: true, defaults: defaults,
            installation: .init(codexInstalled: false, claudeInstalled: false),
            completionDismissalStore: CompletionDismissalStore(fileURL: directory.appendingPathComponent("dismissals.json")))
        return (model, defaults, name, directory)
    }

    func testQuotaComponentsFollowEnabledProvidersWithoutDiscardingLayout() async throws {
        let (model, defaults, name, directory) = try fixture()
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: directory) }
        let layout = CompactIslandLayout(leading: [.quota, .tps], trailing: [.quotaGauge, .activity])
        layout.save(to: defaults)
        let configurations: [Set<AgentProvider>] = [[], [.codex], [.claude], [.codex, .claude]]
        for enabled in configurations {
            ProviderModules(codexMode: enabled.contains(.codex) ? .enabled : .disabled,
                claudeMode: enabled.contains(.claude) ? .enabled : .disabled).save(to: defaults)
            model.applySettings(sourceChanged: false)
            XCTAssertEqual(model.compactLayout, layout, "Applying module choices must keep both saved positions")
            for component in [CompactIslandLayout.Component.quota, .quotaGauge] {
                XCTAssertEqual(CompactIslandComponent.isVisible(component, model: model), !enabled.isEmpty,
                    "Quota components combine whichever modules are enabled")
            }
            XCTAssertTrue(CompactIslandComponent.isVisible(.activity, model: model), "Tasks remain one global component")
            XCTAssertEqual(Set(model.enabledProviders), enabled)
        }
        await model.shutdown()
    }

    func testUnsavedQuotaMetricAndWindowPreviewDoesNotChangeSavedSelectionOrInventPace() async throws {
        let (model, defaults, name, directory) = try fixture()
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_800_000_000); model.now = now
        let data = try JSONSerialization.data(withJSONObject: ["rateLimits": [
            "primary": ["usedPercent": 20, "windowDurationMins": 300, "resetsAt": now.addingTimeInterval(9000).timeIntervalSince1970],
            "secondary": ["usedPercent": 70, "windowDurationMins": 10080, "resetsAt": now.addingTimeInterval(151200).timeIntervalSince1970]]])
        model.quota = try QuotaSnapshot.decode(data, capturedAt: now)
        let primary = try XCTUnwrap(model.quota?.windows.first { $0.durationMinutes == 300 })
        let weekly = try XCTUnwrap(model.quota?.windows.first { $0.durationMinutes == 10080 })
        defaults.set(primary.id, forKey: "quotaWindowID"); defaults.set("remaining", forKey: "compactMetric")
        XCTAssertEqual(model.compactQuotaText(.codex), "80%")
        XCTAssertEqual(model.compactQuotaText(.codex, metric: "pace", selection: weekly.id), "120%")
        XCTAssertEqual(model.compactTimeRemainingText(.codex, selection: weekly.id), "25%")
        XCTAssertEqual(model.compactQuotaText(.codex), "80%")
        XCTAssertEqual(defaults.string(forKey: "quotaWindowID"), primary.id)
        XCTAssertEqual(defaults.string(forKey: "compactMetric"), "remaining")
        model.errorMessage = "Synthetic unavailable quota"
        XCTAssertEqual(model.compactQuotaText(.codex, metric: "pace", selection: weekly.id), "—")
        await model.shutdown()
    }

    func testInlineEditorFitsSettingsPaneAndFollowsProvidersWithoutSaving() async throws {
        let (model, defaults, name, directory) = try fixture()
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: directory) }
        var draft = CompactIslandLayout(leading: [.activity], trailing: [.quotaGauge, .quota])
        let binding = Binding(get: { draft }, set: { draft = $0 })
        func render(_ providers: [AgentProvider], name: String) async throws -> Data {
            let view = CompactLayoutEditor(model: model, layout: binding, providers: Set(providers))
                .padding(16).frame(width: 524).background(Color(nsColor: .windowBackgroundColor))
            let host = NSHostingView(rootView: view)
            let size = host.fittingSize
            XCTAssertLessThanOrEqual(size.width, 525, "The editor must fit the sidebar Settings content, not its old 740-point sheet")
            let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 524, height: size.height),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.title = "Pacer synthetic layout check"; window.contentView = host
            host.frame = NSRect(x: 0, y: 0, width: 524, height: size.height); window.orderFront(nil)
            defer { window.orderOut(nil); window.close() }
            try await Task.sleep(nanoseconds: 100_000_000)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            if let path = ProcessInfo.processInfo.environment["PACER_UI_QA_OUTPUT"] {
                let output = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try png.write(to: output.appendingPathComponent(name + ".png"))
            }
            return png
        }
        let before = defaults.persistentDomain(forName: name) as NSDictionary?
        let codex = try await render([.codex], name: "compact-editor-codex")
        let none = try await render([], name: "compact-editor-none")
        XCTAssertNotEqual(codex, none, "Quota chips leave the lanes while no module is enabled")
        XCTAssertEqual(draft, CompactIslandLayout(leading: [.activity], trailing: [.quotaGauge, .quota]))
        XCTAssertEqual(defaults.persistentDomain(forName: name) as NSDictionary?, before, "Rendering drafts must not save Settings")
        await model.shutdown()
    }
}
