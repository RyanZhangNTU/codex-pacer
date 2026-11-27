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

    func testAntigravitySettingsStagesAndApprovalFloatRenderOffscreen() async throws {
        let model = try demo()
        // XCTest has a generic icon. Give the float the icon from the app bundle.
        let icon = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/Pacer.icns")
        let previousIcon = NSApp.applicationIconImage
        NSApp.applicationIconImage = try XCTUnwrap(NSImage(contentsOf: icon))
        defer { NSApp.applicationIconImage = previousIcon }
        XCTAssertFalse(model.harnessGuideFloat.isShowing, "The ordinary Antigravity demo has no automatic float")
        for stage in [HarnessProgressGuide.Stage.adding, .newConversation, .allowTool, .ready] {
            let snapshot = DemoScenario.antigravityTasks(at: Date(), requestsProgressApproval: stage == .allowTool)
            model.applyDemoAntigravityProgress(snapshot, setup: .init(stage == .adding ? .settingUp : .configured, connection: stage == .ready ? .trusted : nil))
            let guide = try XCTUnwrap(ProgressGuideRows.guide(model, .antigravity, isOn: true))
            XCTAssertEqual(guide.stage, stage)
            XCTAssertTrue(ProgressGuideRows.opens(guide))
            XCTAssertEqual(guide.picture, stage == .ready ? nil : .antigravityApproval)
            for language in AppLanguage.allCases {
                for dark in [false, true] {
                    let suffix = language.rawValue + (dark ? "-dark" : "-light")
                    let settings = ProgressGuideRows(model: model, provider: .antigravity, isOn: .constant(true), language: language)
                        .padding(14).frame(width: 390).background(MainPalette.card)
                    try await render(settings, dark: dark, name: "settings-" + stage.rawValue + "-" + suffix, width: 390)
                    if stage == .allowTool {
                        let float = GuideFloatContent(model: model, float: model.harnessGuideFloat, provider: .antigravity, language: language)
                        try await render(float, dark: dark, name: "float-allowTool-" + suffix, width: GuideFloatContent.width)
                    }
                }
            }
        }
        XCTAssertFalse(model.harnessGuideFloat.isShowing)
    }

    private func render(_ view: some View, dark: Bool, name: String, width: CGFloat) async throws {
        let host = NSHostingView(rootView: view.pacerAccent(PacerAccent.current)
            .environment(\.controlActiveState, .key).environment(\.colorScheme, dark ? .dark : .light).fixedSize(horizontal: false, vertical: true))
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
    }
}
