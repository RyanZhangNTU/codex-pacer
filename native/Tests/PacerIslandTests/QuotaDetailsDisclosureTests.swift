import AppKit
import ApplicationServices
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

    private func accessibleElements(in root: AnyObject) -> [AnyObject] {
        var seen = Set<ObjectIdentifier>(), result: [AnyObject] = []
        func visit(_ element: AnyObject) {
            guard seen.insert(ObjectIdentifier(element)).inserted else { return }
            result.append(element)
            // SwiftUI virtual nodes expose the public Objective-C getters
            // without adopting the complete NSAccessibilityProtocol.
            let children = (element.accessibilityChildren?() ?? []) + ((element as? NSView)?.subviews ?? [])
            for child in children {
                visit(child as AnyObject)
            }
        }
        visit(root)
        return result
    }

    private func accessibilityTitle(of element: AnyObject) -> String? {
        let selector = NSSelectorFromString("accessibilityTitle")
        guard let object = element as? NSObject, object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue() as? String
    }

    private func materializeAccessibilityTree() async {
        // Query this test process while leaving its main thread available to
        // serve the request. This enables the hosted view's lazy AX nodes.
        let result = await Task.detached {
            let application = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
            var windows: CFTypeRef?
            return AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &windows)
        }.value
        XCTAssertEqual(result, .success)
    }

    private func disclosureButton(in host: NSView, title: String) async throws -> AnyObject? {
        let deadline = Date().addingTimeInterval(2)
        repeat {
            host.layoutSubtreeIfNeeded()
            if let button = accessibleElements(in: host).first(where: {
                let role = $0.accessibilityRole?()
                return (role == .button || role == .disclosureTriangle) &&
                    ($0.accessibilityIdentifier?() == "quota.details.disclosure" || $0.accessibilityLabel?() == title || accessibilityTitle(of: $0) == title)
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
            defer { window.orderOut(nil); window.contentView = nil; window.close() }
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            await materializeAccessibilityTree()
            try await Task.sleep(nanoseconds: 50_000_000)
            let candidate = try await disclosureButton(in: host, title: title)
            let roles = accessibleElements(in: host).map { $0.accessibilityRole?()?.rawValue ?? "none" }
            let button = try XCTUnwrap(candidate, "Hosting subtree accessibility roles: \(roles)")
            XCTAssertTrue(button.isAccessibilityEnabled?() ?? false)
            XCTAssertEqual(button.accessibilityLabel?() ?? accessibilityTitle(of: button), title)
            let frame = try XCTUnwrap(button.accessibilityFrame?())
            XCTAssertGreaterThanOrEqual(frame.width, 359,
                "The title and space after it must belong to the button, along with the chevron")
            XCTAssertEqual(button.accessibilityValue?() as? String, L10n.text("account.expiries_collapsed"))
            XCTAssertTrue(button.accessibilityPerformPress?() ?? false)
            XCTAssertTrue(state.expanded)
            try await Task.sleep(nanoseconds: 50_000_000)
            let openCandidate = try await disclosureButton(in: host, title: title)
            let openButton = try XCTUnwrap(openCandidate)
            XCTAssertEqual(openButton.accessibilityValue?() as? String, L10n.text("account.expiries_expanded"))
            XCTAssertTrue(openButton.accessibilityPerformPress?() ?? false)
            XCTAssertFalse(state.expanded)
        }
    }
}
