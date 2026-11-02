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
    private struct Fixture: View {
        @ObservedObject var state: DisclosureState
        let title: String

        var body: some View {
            DisclosureGroup(title, isExpanded: $state.expanded) {
                Text("Synthetic quota window").frame(height: 80)
            }
            .disclosureGroupStyle(FullRowDisclosureStyle())
            .frame(width: 360)
        }
    }

    private func disclosureButton(in element: any NSAccessibilityProtocol) -> (any NSAccessibilityProtocol)? {
        if element.accessibilityIdentifier() == "quota.details.disclosure", element.accessibilityRole() == .button { return element }
        for child in element.accessibilityChildren() ?? [] {
            if let accessible = child as? any NSAccessibilityProtocol, let button = disclosureButton(in: accessible) { return button }
        }
        return nil
    }

    func testFullRowIsOneAccessibleButtonThatExpandsAndCollapses() async throws {
        _ = NSApplication.shared
        for language in AppLanguage.allCases {
            let state = DisclosureState()
            let title = L10n.text("settings.quota_details", language: language)
            let host = NSHostingView(rootView: Fixture(state: state, title: title))
            let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 360, height: 160),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
            defer { window.orderOut(nil); window.close() }
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 50_000_000)
            let button = try XCTUnwrap(disclosureButton(in: host))
            XCTAssertEqual(button.accessibilityLabel() ?? button.accessibilityTitle(), title)
            XCTAssertGreaterThanOrEqual(button.accessibilityFrame().width, 359,
                "The title and space after it must belong to the button, along with the chevron")
            XCTAssertEqual(button.accessibilityValue() as? String, L10n.text("account.expiries_collapsed"))
            XCTAssertTrue(button.accessibilityPerformPress())
            XCTAssertTrue(state.expanded)
            try await Task.sleep(nanoseconds: 50_000_000)
            let openButton = try XCTUnwrap(disclosureButton(in: host))
            XCTAssertEqual(openButton.accessibilityValue() as? String, L10n.text("account.expiries_expanded"))
            XCTAssertTrue(openButton.accessibilityPerformPress())
            XCTAssertFalse(state.expanded)
        }
    }
}
