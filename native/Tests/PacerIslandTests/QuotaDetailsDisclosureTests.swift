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
            .accessibilityElement(children: .contain)
        }
    }

    private func accessibleElements(in root: any NSAccessibilityProtocol) -> [any NSAccessibilityProtocol] {
        var seen = Set<ObjectIdentifier>(), result: [any NSAccessibilityProtocol] = []
        func visit(_ element: any NSAccessibilityProtocol) {
            guard seen.insert(ObjectIdentifier(element as AnyObject)).inserted else { return }
            result.append(element)
            let children = (element.accessibilityChildren() ?? []) + ((element as? NSView)?.subviews ?? [])
            for child in children {
                if let accessible = child as? any NSAccessibilityProtocol { visit(accessible) }
            }
        }
        visit(root)
        return result
    }

    private func disclosureButton(in host: NSView, title: String) async throws -> (any NSAccessibilityProtocol)? {
        let deadline = Date().addingTimeInterval(2)
        repeat {
            host.layoutSubtreeIfNeeded()
            if let button = accessibleElements(in: host).first(where: {
                let role = $0.accessibilityRole()
                return (role == .button || role == .disclosureTriangle) &&
                    ($0.accessibilityIdentifier() == "quota.details.disclosure" || $0.accessibilityLabel() == title || $0.accessibilityTitle() == title)
            }) { return button }
            try await Task.sleep(nanoseconds: 20_000_000)
        } while Date() < deadline
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
            window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
            defer { window.orderOut(nil); window.close() }
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 50_000_000)
            let candidate = try await disclosureButton(in: host, title: title)
            let roles = accessibleElements(in: host).map { $0.accessibilityRole()?.rawValue ?? "none" }
            let button = try XCTUnwrap(candidate, "Hosting subtree accessibility roles: \(roles)")
            XCTAssertTrue(button.isAccessibilityEnabled())
            XCTAssertEqual(button.accessibilityLabel() ?? button.accessibilityTitle(), title)
            XCTAssertGreaterThanOrEqual(button.accessibilityFrame().width, 359,
                "The title and space after it must belong to the button, along with the chevron")
            XCTAssertEqual(button.accessibilityValue() as? String, L10n.text("account.expiries_collapsed"))
            XCTAssertTrue(button.accessibilityPerformPress())
            XCTAssertTrue(state.expanded)
            try await Task.sleep(nanoseconds: 50_000_000)
            let openCandidate = try await disclosureButton(in: host, title: title)
            let openButton = try XCTUnwrap(openCandidate)
            XCTAssertEqual(openButton.accessibilityValue() as? String, L10n.text("account.expiries_expanded"))
            XCTAssertTrue(openButton.accessibilityPerformPress())
            XCTAssertFalse(state.expanded)
        }
    }
}
