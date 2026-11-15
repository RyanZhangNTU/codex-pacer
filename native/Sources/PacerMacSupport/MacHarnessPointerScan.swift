import AppKit
import ApplicationServices
import Foundation
import PacerCore

/// Finds the buttons the progress ring's setup asks the user to click in a
/// local module's app, so Pacer can point at them. It reads only roles,
/// names and positions from the app's front window, never clicks, and keeps
/// nothing it reads.
package enum MacHarnessPointerScan {
    package struct Element: Equatable, Sendable {
        package let role: String
        package let name: String
        /// In screen points, from the top left of the main display, as Accessibility reports it.
        package let frame: CGRect

        package init(role: String, name: String, frame: CGRect) {
            self.role = role; self.name = name; self.frame = frame
        }
    }

    package struct Result: Equatable, Sendable {
        /// The page the app shows, when its buttons tell.
        package var view: HarnessProgressGuide.AppView?
        package var customConnector: CGRect?
        /// The Trust button on Pacer's entry.
        package var trust: CGRect?
    }

    static let customNames: Set<String> = ["自定义连接器", "custom connector", "custom connectors"]
    static let trustNames: Set<String> = ["信任", "trust"]
    static let server = "pacer_progress"
    private static let buttonRole = kAXButtonRole as String

    /// Whether Pacer may read other apps' buttons; asks the system once when `prompt` is set.
    package static func trusted(prompt: Bool) -> Bool {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": prompt] as CFDictionary)
    }

    /// Picks the buttons out of what the app's window lists: Custom Connector
    /// on the connectors page, and once Pacer's entry shows, the Trust button
    /// on it rather than on another connector.
    package static func result(_ elements: [Element]) -> Result {
        func key(_ name: String) -> String { name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let buttons = elements.filter { $0.role == buttonRole && !$0.frame.isEmpty }
        let custom = buttons.first { customNames.contains(key($0.name)) }
        let entries = elements.filter { $0.name.contains(server) && !$0.frame.isEmpty }
        let trusts = buttons.filter { trustNames.contains(key($0.name)) }
        // The entry's own button sits level with or below its name, on its card.
        func score(_ button: Element) -> CGFloat {
            entries.map { entry -> CGFloat in
                let dy = button.frame.midY - entry.frame.midY, dx = button.frame.midX - entry.frame.midX
                let onCard = button.frame.maxY >= entry.frame.minY - 4 && button.frame.maxX >= entry.frame.minX - 8
                return (onCard ? 0 : 10_000) + abs(dy) + abs(dx) * 0.35
            }.min() ?? .infinity
        }
        let trust = entries.isEmpty ? nil : trusts.min { score($0) < score($1) }
        let view: HarnessProgressGuide.AppView? = !entries.isEmpty ? .customConnectors : custom != nil ? .connectors : nil
        return Result(view: view, customConnector: custom?.frame, trust: trust?.frame)
    }

    /// Reads the front window of the app with `pid`, within a time and size
    /// budget. Electron apps build their tree only once asked to.
    package static func scan(pid: pid_t, budget: TimeInterval = 0.25, limit: Int = 5000) -> Result? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        func value(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
            var result: AnyObject?
            return AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success ? result : nil
        }
        guard let window = (value(app, kAXFocusedWindowAttribute) ?? value(app, kAXMainWindowAttribute)
                            ?? (value(app, kAXWindowsAttribute) as? [AnyObject])?.first) else { return nil }
        let attributes = [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute,
                          kAXPositionAttribute, kAXSizeAttribute, kAXChildrenAttribute] as CFArray
        let deadline = Date().addingTimeInterval(budget)
        var queue = [window as! AXUIElement], index = 0, found: [Element] = []
        while index < queue.count, index < limit, Date() < deadline {
            let element = queue[index]; index += 1
            var raw: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(element, attributes, [], &raw) == .success,
                  let values = raw as? [AnyObject], values.count == 7 else { continue }
            let role = values[0] as? String ?? ""
            var name = [values[1], values[2], values[3]].lazy.compactMap { $0 as? String }.first { !$0.isEmpty } ?? ""
            let children = values[6] as? [AXUIElement] ?? []
            // A web button often carries its label in a text child.
            if role == buttonRole, name.isEmpty {
                name = children.prefix(3).lazy.compactMap { value($0, kAXValueAttribute) as? String ?? value($0, kAXTitleAttribute) as? String }
                    .first { !$0.isEmpty } ?? ""
            }
            if role == buttonRole || name.contains(server) {
                var origin = CGPoint.zero, size = CGSize.zero
                if CFGetTypeID(values[4]) == AXValueGetTypeID() { AXValueGetValue(values[4] as! AXValue, .cgPoint, &origin) }
                if CFGetTypeID(values[5]) == AXValueGetTypeID() { AXValueGetValue(values[5] as! AXValue, .cgSize, &size) }
                found.append(Element(role: role, name: name, frame: CGRect(origin: origin, size: size)))
            }
            if queue.count < limit * 2 { queue.append(contentsOf: children) }
        }
        return result(found)
    }
}
