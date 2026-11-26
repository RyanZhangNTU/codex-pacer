import AppKit
import SwiftUI
import XCTest
import PacerCore
@testable import PacerIsland

final class AntigravityProgressGuideViewTests: XCTestCase {
    @MainActor
    func testApprovalInstructionsFitTheGuideInBothLanguages() async throws {
        for language in AppLanguage.allCases {
            let guide = try XCTUnwrap(HarnessProgressGuide(setup: .configured, connection: nil, reported: false, ringOn: true,
                name: "Antigravity", pluginPlatform: .macOS, requestsApproval: true, language: language))
            let view = ProgressGuideBody(guide: guide, provider: .antigravity, perform: { _ in })
                .padding(12).frame(width: 360).fixedSize(horizontal: false, vertical: true)
                .background(Color(nsColor: .windowBackgroundColor))
            let host = NSHostingView(rootView: view)
            let bounds = NSRect(origin: .zero, size: host.fittingSize)
            XCTAssertEqual(bounds.width, 360, accuracy: 1)
            XCTAssertGreaterThan(bounds.height, 100)
            let window = NSWindow(contentRect: bounds, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = "Pacer synthetic progress guide"
            window.contentView = host
            window.orderFront(nil)
            defer { window.orderOut(nil); window.close() }
            try await Task.sleep(nanoseconds: 100_000_000)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            if let path = ProcessInfo.processInfo.environment["PACER_UI_QA_OUTPUT"] {
                let directory = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try png.write(to: directory.appendingPathComponent("antigravity-guide-" + language.rawValue + ".png"))
            }
        }
    }
}
