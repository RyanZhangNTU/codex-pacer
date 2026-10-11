import AppKit

/// Esc is a window action even when no SwiftUI control has keyboard focus.
/// Use the same native close path as Command-W and the red close control, so
/// releasing the hosting view also flushes pending Settings edits. While an
/// input method is composing text, Esc belongs to it and cancels the composition.
@MainActor
final class SettingsWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let composing = (firstResponder as? NSTextView)?.hasMarkedText() == true
        guard event.type == .keyDown, event.keyCode == 53, modifiers.isEmpty, !composing else {
            return super.performKeyEquivalent(with: event)
        }
        cancelOperation(nil)
        return true
    }

    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }
}
