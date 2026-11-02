import AppKit
import SwiftUI
import XCTest
import PacerCore
@testable import PacerIsland

@MainActor
final class QuotaDetailsDisclosureTests: XCTestCase {
    @MainActor private final class DisclosureState: ObservableObject {
        @Published var expanded = false
    }
    @MainActor private final class ButtonProbe {
        var width: CGFloat = 0
        var trigger: (() -> Void)?

        func press() -> Bool {
            guard let trigger else { return false }
            trigger()
            return true
        }
    }
    private struct ProbeStyle: PrimitiveButtonStyle {
        let probe: ButtonProbe

        func makeBody(configuration: Configuration) -> some View {
            Button(configuration)
                .buttonStyle(.plain)
                .background(GeometryReader { geometry in
                    Color.clear
                        .onAppear { probe.width = geometry.size.width }
                        .onChange(of: geometry.size) { _, size in probe.width = size.width }
                })
                .onAppear { probe.trigger = { configuration.trigger() } }
        }
    }
    private struct Fixture: View {
        @ObservedObject var state: DisclosureState
        let title: String
        let probe: ButtonProbe

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                FullRowDisclosureStyle().header(isExpanded: $state.expanded, label: Text(title), buttonStyle: ProbeStyle(probe: probe))
                if state.expanded { Text("Synthetic quota window").frame(height: 80) }
            }
            .frame(width: 360, alignment: .leading)
        }
    }

    func testStyleButtonCoversTheWholeRowAndItsActionExpandsAndCollapses() async throws {
        _ = NSApplication.shared
        for language in AppLanguage.allCases {
            let state = DisclosureState(), probe = ButtonProbe()
            let title = L10n.text("settings.quota_details", language: language)
            XCTAssertEqual(title, language == .english ? "Quota details" : "额度详情")
            let host = NSHostingView(rootView: Fixture(state: state, title: title, probe: probe))
            let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 360, height: 160),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
            defer { probe.trigger = nil; window.orderOut(nil); window.contentView = nil; window.close() }
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try await Task.sleep(nanoseconds: 50_000_000)
            _ = try XCTUnwrap(probe.trigger, "The probe must capture the actual style button's action")
            XCTAssertFalse(state.expanded)
            XCTAssertGreaterThanOrEqual(probe.width, 359,
                "The title and right-hand blank space must belong to the same full-width button")
            let collapsedHeight = host.fittingSize.height
            XCTAssertTrue(probe.press())
            XCTAssertTrue(state.expanded, "Pressing the full-row button expands its bound disclosure")
            try await Task.sleep(nanoseconds: 50_000_000)
            host.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(host.fittingSize.height, collapsedHeight, "The details become visible after expansion")
            XCTAssertGreaterThanOrEqual(probe.width, 359, "Expansion keeps the whole header clickable")
            XCTAssertTrue(probe.press())
            XCTAssertFalse(state.expanded, "Pressing the same full-row button again collapses it")
            try await Task.sleep(nanoseconds: 50_000_000)
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(host.fittingSize.height, collapsedHeight, accuracy: 1, "Collapsing hides the details again")
        }
    }
}
