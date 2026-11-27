import AppKit
import SwiftUI
import XCTest
import PacerCore
import PacerTestSupport
@testable import PacerIsland

@MainActor
final class AntigravityProgressGuideViewTests: XCTestCase {
    private func demo(autoOpen: Bool = false) throws -> IslandModel {
        let domain = testDefaultsName("antigravity-guide")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        let model = IslandModel(demo: true, demoArguments: autoOpen ? ["--demo-antigravity", "--demo-antigravity-guide"] : ["--demo-antigravity"],
                                defaults: defaults)
        addTeardownBlock {
            await model.harnessGuideFloat.close()
            await model.shutdown()
            removeTestDefaults(domain)
        }
        return model
    }

    func testAntigravityFloatFollowsTheGuideAndRemembersDismissedApprovals() async throws {
        let model = try demo(autoOpen: true)
        let float = model.harnessGuideFloat
        model.setDemoStage(.tool)
        XCTAssertEqual(model.progressGuide(.antigravity)?.stage, .newConversation)
        XCTAssertFalse(float.isShowing)
        let opened = await model.openHarnessGuideApp(.antigravity, screen: nil)
        XCTAssertTrue(opened)
        XCTAssertTrue(float.isShowing)
        XCTAssertTrue(float.followsApp)
        float.close()

        let pending = DemoScenario.antigravityTasks(at: Date())
        model.applyDemoAntigravityProgress(pending, setup: .init(.settingUp))
        XCTAssertEqual(model.progressGuide(.antigravity)?.stage, .adding)
        XCTAssertTrue(float.isShowing, "A pending card opens immediately, even during installation")
        XCTAssertEqual(model.progressGuide(.antigravity)?.floatPicture, .antigravityApproval)
        model.setDemoStage(.responding)
        XCTAssertTrue(float.isShowing)
        XCTAssertEqual(model.progressGuide(.antigravity)?.picture, .antigravityApproval)
        float.close()
        model.setDemoStage(.tool)
        model.setDemoStage(.responding)
        XCTAssertFalse(float.isShowing, "The same request can disappear for a poll without becoming a new approval")

        var next = DemoScenario.antigravityTasks(at: Date())
        var other = try XCTUnwrap(next.requests.first)
        other.requestsProgressApproval = false
        var fresh = PendingAttentionRequest(id: "second", threadID: other.threadID, sourceHostID: nil, sourceName: nil,
                                            kind: .approval, detectedAt: Date(), provider: .antigravity)
        next.requests = [other, fresh]
        model.applyDemoAntigravityProgress(next, setup: .init(.configured))
        XCTAssertFalse(float.isShowing, "Other tools do not open the guide")
        fresh.requestsProgressApproval = true
        next.requests = [other, fresh]
        model.applyDemoAntigravityProgress(next, setup: .init(.configured))
        XCTAssertTrue(float.isShowing, "A different pending request opens its guide")
        model.applyDemoAntigravityProgress(next, setup: .init(.configured, reported: true))
        let guide = try XCTUnwrap(model.progressGuide(.antigravity))
        XCTAssertEqual(guide.stage, .ready)
        XCTAssertEqual(guide.floatTitle, guide.line)
        let now = Date()
        float.update(at: now)
        float.update(at: now.addingTimeInterval(HarnessGuideFloat.doneShown - 0.1))
        XCTAssertTrue(float.isShowing)
        float.update(at: now.addingTimeInterval(HarnessGuideFloat.doneShown))
        XCTAssertFalse(float.isShowing)
        var unseen = PendingAttentionRequest(id: "unseen", threadID: other.threadID, sourceHostID: nil, sourceName: nil,
                                            kind: .approval, detectedAt: Date(), provider: .antigravity)
        unseen.requestsProgressApproval = true
        next.requests = [unseen]
        for state in [LocalHarnessProgressSetup.State(.configured, reported: true), .init(.configured, connection: .trusted)] {
            model.applyDemoAntigravityProgress(next, setup: state)
            XCTAssertFalse(float.isShowing, "Ready never opens a guide, even for a new request")
        }
    }

    func testMissedConversationOpensTheFloatOnceAndYieldsToApprovalOrReady() throws {
        let model = try demo(autoOpen: true)
        let float = model.harnessGuideFloat
        model.setDemoStage(.tool, missedProgressTool: true)
        XCTAssertEqual(model.progressGuide(.antigravity)?.stage, .conversationMissedTool)
        XCTAssertTrue(float.isShowing)
        float.close()
        model.setDemoStage(.tool)
        model.setDemoStage(.tool, missedProgressTool: true)
        XCTAssertFalse(float.isShowing)
        let now = Date(), installed = now.addingTimeInterval(-20)
        var snapshot = DemoScenario.antigravityTasks(at: now, requestsProgressApproval: false)
        snapshot.missedProgressConversation = .init(id: "second", firstInputAt: now)
        model.applyDemoAntigravityProgress(snapshot, setup: .init(.configured, addedAt: installed))
        XCTAssertTrue(float.isShowing)
        float.close()
        snapshot.missedProgressConversation = .init(id: "third", firstInputAt: now)
        model.applyDemoAntigravityProgress(snapshot, setup: .init(.configured, connection: .trusted, addedAt: installed))
        XCTAssertFalse(float.isShowing)
        model.setDemoStage(.responding)
        XCTAssertEqual(model.progressGuide(.antigravity)?.stage, .allowTool)
        XCTAssertTrue(float.isShowing, "Seeing a miss does not consume the approval's auto-open")
    }

    func testAntigravitySettingsAndFloatRenderOffscreenAndCopyTheExample() async throws {
        let model = try demo()
        // XCTest has a generic icon. Give the float the icon from the app bundle.
        let icon = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/Pacer.icns")
        let app = NSApplication.shared
        let previousIcon = app.applicationIconImage
        app.applicationIconImage = try XCTUnwrap(NSImage(contentsOf: icon))
        defer { app.applicationIconImage = previousIcon }
        XCTAssertFalse(model.harnessGuideFloat.isShowing, "The ordinary Antigravity demo has no automatic float")
        for stage in [HarnessProgressGuide.Stage.adding, .newConversation, .conversationMissedTool, .allowTool, .ready] {
            let now = Date()
            var snapshot = DemoScenario.antigravityTasks(at: now, requestsProgressApproval: stage == .allowTool)
            if stage == .conversationMissedTool { snapshot.missedProgressConversation = .init(id: "missed", firstInputAt: now) }
            model.applyDemoAntigravityProgress(snapshot, setup: .init(stage == .adding ? .settingUp : .configured, connection: stage == .ready ? .trusted : nil, addedAt: now.addingTimeInterval(-1)))
            let guide = try XCTUnwrap(ProgressGuideRows.guide(model, .antigravity, isOn: true))
            XCTAssertEqual(guide.stage, stage)
            XCTAssertTrue(ProgressGuideRows.opens(guide))
            XCTAssertEqual(guide.picture, stage == .ready ? nil : .antigravityApproval)
            let hasExample = stage == .newConversation || stage == .conversationMissedTool
            for language in AppLanguage.allCases {
                let example = hasExample ? try XCTUnwrap(model.progressGuide(.antigravity, language: language)?.example) : nil
                for dark in [false, true] {
                    let suffix = language.rawValue + (dark ? "-dark" : "-light")
                    let settings = ProgressGuideRows(model: model, provider: .antigravity, isOn: .constant(true), language: language)
                        .padding(14).frame(width: 390).background(MainPalette.card)
                    try await render(settings, dark: dark, name: "settings-" + stage.rawValue + "-" + suffix, width: 390, language: language, example: example)
                    if hasExample || stage == .allowTool {
                        let float = GuideFloatContent(model: model, float: model.harnessGuideFloat, provider: .antigravity, language: language)
                        try await render(float, dark: dark, name: "float-" + stage.rawValue + "-" + suffix, width: GuideFloatContent.width,
                                         language: language, example: example)
                    }
                }
            }
        }
        XCTAssertFalse(model.harnessGuideFloat.isShowing)
    }

    private func render(_ view: some View, dark: Bool, name: String, width: CGFloat, language: AppLanguage, example: String?) async throws {
        let host = NSHostingView(rootView: view.pacerAccent(PacerAccent.current)
            .environment(\.accessibilityEnabled, true).environment(\.controlActiveState, .key)
            .environment(\.colorScheme, dark ? .dark : .light).fixedSize(horizontal: false, vertical: true))
        let size = host.fittingSize
        XCTAssertEqual(size.width, width, accuracy: 1)
        XCTAssertGreaterThan(size.height, 30)
        let frame = NSRect(origin: CGPoint(x: -20_000, y: -20_000), size: size)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrame(frame, display: true)
        window.orderBack(nil)
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(for: .milliseconds(80))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        if let path = ProcessInfo.processInfo.environment["PACER_UI_QA_OUTPUT"] {
            let directory = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try png.write(to: directory.appendingPathComponent(name + ".png"))
        }
        let copyButton = button(named: L10n.text("progress_guide.action.copy", language: language), in: host)
        guard let example else {
            XCTAssertNil(copyButton, name)
            return
        }
        let item = NSPasteboardItem()
        let original = TextClipboard.write
        defer { TextClipboard.write = original }
        TextClipboard.write = { item.setString($0, forType: .string) }
        XCTAssertEqual(try XCTUnwrap(copyButton, name).accessibilityPerformPress?(), true)
        XCTAssertEqual(item.string(forType: .string), example, name)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertNotNil(button(named: L10n.text("support.share.copied", language: language), in: host), name)
    }

    private func button(named label: String, in element: AnyObject) -> AnyObject? {
        if element.accessibilityRole?() == .button, element.accessibilityLabel?() == label { return element }
        for child in element.accessibilityChildren?() ?? [] {
            if let found = button(named: label, in: child as AnyObject) { return found }
        }
        return nil
    }
}
