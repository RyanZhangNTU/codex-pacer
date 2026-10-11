import AppKit
import XCTest
@testable import PacerIsland

@MainActor
final class SettingsWindowTests: XCTestCase {
    private final class ConsumingContentView: NSView {
        var received = 0
        override func performKeyEquivalent(with event: NSEvent) -> Bool { received += 1; return true }
    }
    private final class Delegate: NSObject, NSWindowDelegate {
        var closes = 0
        func windowWillClose(_ notification: Notification) {
            closes += 1
            (notification.object as? NSWindow)?.contentView = nil
        }
    }
    private func key(_ flags: NSEvent.ModifierFlags = [], code: UInt16 = 53, characters: String = "\u{1b}",
                     window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 1,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }

    func testEscapeUsesNativeCloseBeforeFocusedContentCanConsumeIt() throws {
        _ = NSApplication.shared
        let modifiers: [NSEvent.ModifierFlags?] = [[], .capsLock, nil]
        for flags in modifiers {
            let window = SettingsWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 200),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let delegate = Delegate(), content = ConsumingContentView()
            window.delegate = delegate; window.contentView = content
            if let flags { XCTAssertTrue(window.performKeyEquivalent(with: try key(flags, window: window))) }
            else { window.cancelOperation(nil) }
            XCTAssertEqual(delegate.closes, 1, "Esc and responder-chain cancel use the native close path")
            XCTAssertNil(window.contentView, "Esc must use the close path that releases Settings content")
            XCTAssertEqual(content.received, 0)
        }
    }

    func testEscapeCancelsInputMethodCompositionInsteadOfClosing() throws {
        _ = NSApplication.shared
        let window = SettingsWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let delegate = Delegate(), field = NSTextView(frame: CGRect(x: 0, y: 0, width: 200, height: 24))
        window.delegate = delegate; window.contentView = field
        XCTAssertTrue(window.makeFirstResponder(field))
        field.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(field.hasMarkedText())
        _ = window.performKeyEquivalent(with: try key(window: window))
        XCTAssertEqual(delegate.closes, 0, "Esc while composing belongs to the input method")
        field.unmarkText()
        XCTAssertTrue(window.performKeyEquivalent(with: try key(window: window)))
        XCTAssertEqual(delegate.closes, 1, "Once composition ends, Esc closes Settings again")
    }

    func testModifiedEscapeReturnAndCommandWRetainTheirResponderChain() throws {
        _ = NSApplication.shared
        let window = SettingsWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let delegate = Delegate(), content = ConsumingContentView()
        window.delegate = delegate; window.contentView = content
        for modifiers: NSEvent.ModifierFlags in [.command, .option, .control, .shift] {
            XCTAssertTrue(window.performKeyEquivalent(with: try key(modifiers, window: window)))
        }
        XCTAssertTrue(window.performKeyEquivalent(with: try key(code: 36, characters: "\r", window: window)))
        XCTAssertTrue(window.performKeyEquivalent(with: try key(.command, code: 13, characters: "w", window: window)))
        XCTAssertEqual(content.received, 6)
        XCTAssertEqual(delegate.closes, 0)
    }
}
