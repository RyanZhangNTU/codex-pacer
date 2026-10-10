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

    func testQuotaComponentsFollowLiveAndUnsavedProviderChoicesWithoutDiscardingLayout() async throws {
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
            let preview = CompactQuotaPreview(providers: [.claude], metric: "remaining", windowIDs: [:])
            XCTAssertTrue(CompactIslandComponent.isVisible(.quota, model: model, quotaPreview: preview))
            XCTAssertFalse(CompactIslandComponent.isVisible(.quota, model: model,
                quotaPreview: CompactQuotaPreview(providers: [], metric: "remaining", windowIDs: [:])))
            XCTAssertEqual(Set(model.enabledProviders), enabled, "Previewing a draft must not turn collectors on or off")
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

    func testInlineEditorFitsSettingsPaneAndRendersProviderChangesWithoutSaving() async throws {
        let (model, defaults, name, directory) = try fixture()
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: directory) }
        var draft = CompactIslandLayout(leading: [.activity], trailing: [.quotaGauge, .quota])
        let binding = Binding(get: { draft }, set: { draft = $0 })
        func render(_ providers: [AgentProvider], name: String) async throws -> Data {
            let view = CompactLayoutEditor(model: model, layout: binding, widthSettings: .constant(.init()), attached: false,
                quotaPreview: .init(providers: providers, metric: "remaining", windowIDs: [:]))
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
        let both = try await render([.codex, .claude], name: "compact-editor-both")
        let codex = try await render([.codex], name: "compact-editor-codex")
        let none = try await render([], name: "compact-editor-none")
        XCTAssertNotEqual(both, codex); XCTAssertNotEqual(codex, none)
        XCTAssertEqual(draft, CompactIslandLayout(leading: [.activity], trailing: [.quotaGauge, .quota]))
        XCTAssertEqual(defaults.persistentDomain(forName: name) as NSDictionary?, before, "Rendering drafts must not save Settings")
        await model.shutdown()
    }

    func testNotchPreviewMarksRealHardwareAtBothScalesWithoutReservingFloatingContent() async throws {
        let (model, defaults, name, directory) = try fixture()
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: directory) }
        model.isAttached = false; model.notchWidth = 0; model.updateMeasuredCompactWidth(220)
        func render(notch: CGSize, attached: Bool, width: CGFloat, name: String) async throws -> (NSBitmapImageRep, CGFloat) {
            model.screenNotchSize = notch
            var measured: CGFloat = 0
            let view = IslandWidthControl(model: model, settings: .constant(.init()), layout: .init(), attached: attached)
                .frame(width: width).preferredColorScheme(.dark)
                .onPreferenceChange(CompactHeaderIdealWidth.self) { measured = $0 }
            let host = NSHostingView(rootView: view)
            let size = host.fittingSize
            let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: width, height: size.height),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.title = "Pacer synthetic notch preview"; window.contentView = host
            host.frame = NSRect(origin: .zero, size: size); window.orderFront(nil)
            defer { window.orderOut(nil); window.close() }
            try await Task.sleep(nanoseconds: 100_000_000)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if let path = ProcessInfo.processInfo.environment["PACER_UI_QA_OUTPUT"] {
                let output = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: output.appendingPathComponent(name + ".png"))
            }
            return (bitmap, measured)
        }
        let hardware = CGSize(width: 184, height: 36)
        let plain = try await render(notch: .zero, attached: false, width: 480, name: "preview-no-notch")
        let floating = try await render(notch: hardware, attached: false, width: 480, name: "preview-notch-floating")
        XCTAssertGreaterThan(floating.0.pixelsHigh, plain.0.pixelsHigh, "Physical notch annotation sits above a floating bar")
        XCTAssertEqual(floating.1, plain.1, "A physical notch must not reserve a center gap in floating content")
        XCTAssertGreaterThan(plain.1, 0)
        for width in [CGFloat(480), CGFloat(180)] {
            let (bitmap, measured) = try await render(notch: hardware, attached: true, width: width, name: "preview-notch-\(Int(width))")
            XCTAssertGreaterThan(measured, floating.1, "The draft attached layout reserves the actual hardware despite the live floating mode")
            let naturalWidth = max(hardware.width + 60, measured + 2)
            let scale = min(1, (width - 24) / naturalWidth)
            let pixelsPerPoint = CGFloat(bitmap.pixelsWide) / width
            let center = bitmap.pixelsWide / 2
            let outside = Int((hardware.width / 2 + 10) * scale * pixelsPerPoint)
            func brightness(_ x: Int, _ y: Int) -> CGFloat {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return 0 }
                return (color.redComponent + color.greenComponent + color.blueComponent) / 3
            }
            let markedRows = (0..<bitmap.pixelsHigh).filter { y in
                brightness(center, y) > 0.08 && brightness(center - outside, y) < 0.02 && brightness(center + outside, y) < 0.02
            }
            XCTAssertGreaterThan(markedRows.count, Int(8 * scale * pixelsPerPoint),
                "The centered physical cutout must remain visibly distinct from both black content wings after scaling")
        }
        let forced = try await render(notch: .zero, attached: true, width: 480, name: "preview-forced-no-notch")
        XCTAssertEqual(forced.1, plain.1, "Forcing Notch mode on an unnotched screen must not invent hardware")
        XCTAssertEqual(model.notchWidth, 0); XCTAssertFalse(model.isAttached)
        XCTAssertEqual(model.measuredCompactWidth, 220, "Preview choices must not resize the actual island")
        await model.shutdown()
    }
}
