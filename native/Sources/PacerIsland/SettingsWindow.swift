import AppKit

/// Esc is a window action even when no SwiftUI control has keyboard focus.
/// Use the same native close path as Command-W and the red close control, so
/// releasing the hosting view also flushes pending Settings edits.
@MainActor
final class SettingsWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard event.type == .keyDown, event.keyCode == 53, modifiers.isEmpty else {
            return super.performKeyEquivalent(with: event)
        }
        cancelOperation(nil)
        return true
    }

    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }
}
